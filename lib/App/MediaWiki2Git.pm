use strict;
use warnings;
package App::MediaWiki2Git;

use Moose;
use Git::Repository;
use MediaWiki::API;
use YAML qw( LoadFile Dump );
use File::Slurp qw( write_file );
use Net::DNS;
use Carp;

=head1 NAME

App::MediaWiki2Git - copy MediaWiki page history into a Git repository

=head1 DESCRIPTION

This is a workaround for the lack of an "annotate" (aka. "blame")
feature in the MediaWiki we use locally.

It operates using configuration in and upon a Git repository at the
current directory.


=head1 CONFIGURATION

By default, it expects F<mw2git.yaml> to exist in the current directory.

This should contain one hash (dictionary), whose entries are used to
configure parts of this package.

This configuration may be extended and (atomically) replaced as
fetching progresses.

XXX: errors during a run can leave the config out of sync with the committed pages
so page revisions may get committed again.  One solution would be to
C<reset --hard> to the last config save commit.  This could be
automated, at some cost to the principle of least surprise.


=cut

has config_filename => (is => 'ro', isa => 'Str', lazy_build => 1);
has config => (is => 'rw', isa => 'HashRef', lazy_build => 1);

sub _build_config_filename {
    return "mw2git.yaml";
}

sub _build_config {
    my ($self) = @_;
    my $fn = $self->config_filename;
    my @config = LoadFile($fn);
    die "$fn: Should contain one Hash (dictionary) for configuration\n"
      unless 1 == @config && ref($config[0]) eq 'HASH';

    return $config[0];
}

sub config_for {
    my ($self, $key, $type, $default) = @_;

    my $val = $self->config->{$key};
    $val = $default if !defined $val;
    croak "Required configuration key '$key' is missing"
      unless defined $val;
    croak "Configuration key '$key' isa ".ref($val).", but should be a $type"
      if defined $type && $type ne ref($val);

    return $val;
}

sub config_save {
    my ($self) = @_;
    my $fn = $self->config_filename;

    write_file($fn, { atomic => 1 },
               Dump($self->config));

    $self->git->run(add => $fn);
    $self->git->run
      (commit => '-q',
       -m => 'automatic config_save',
       -o => $fn);

    return 1;
}


=head1 MEDIAWIKI INTERFACE

The config key C<mediawiki> should contain a hash suitable for passing
to L<MediaWiki::API/new>.

One entry for C<api_url>, constructed by replacing the C<index.php> in
"http://...server.../wiki/index.php" with C<api.php> should be enough.

=cut

has MW => (is => 'ro', isa => 'MediaWiki::API', lazy_build => 1);

sub _build_MW {
    my ($self) = @_;
    my $mwcfg = $self->config_for(mediawiki => 'HASH');
    warn "Expected at least a ->{mediawiki}->{api_url} entry in the configuration"
      unless ref($mwcfg) eq 'HASH' && $$mwcfg{api_url};

    return MediaWiki::API->new($mwcfg);
}

sub _mw_error {
    my ($self) = @_;
    my $mw = $self->MW;
    die $mw->{error}->{code} . ': ' . $mw->{error}->{details};
}

sub rvlimit {
    my ($self) = @_;
    return $self->config_for(rvlimit => '', 500);
}

sub go {
    my ($self) = @_;
    my $mw = $self->MW;

    # There are several ways to dice the revision number fetching.
    # This keeps track of latest revision per-page, in our config.

    my $more;
    do {
        $more = 0;
        foreach my $pagename ($self->pages) {
            my $rv = $self->page_lastrev($pagename);
            $rv++ if $rv > 0; # avoid re-fetching the last, for tidiness & quiet

            my $q = $mw->api
              ({ action => 'query',
                 prop => 'revisions',
                 titles => $pagename,
                 rvstartid => $rv,
                 rvdir => 'newer',
                 rvlimit => $self->rvlimit,
                 rvprop => 'ids|flags|timestamp|user|comment|content' })
                || $self->_mw_error;

            $self->_save_revs(%{ $q->{query}->{pages} }); # one pair
            $more ||= $q->{'query-continue'};
        }
    } while ($more);
}


=head1 GIT INTERFACE

Uses L<Git::Repository> to drive Git upon the current directory.

It is assumed that the previous requirement for the existence of the
configuration file is enough of a sanity check, to prevent messing
with any other Git repositories' history.

You need to initialise the empty repository directory with a suitable
configuration file.

=cut

has git => (is => 'rw', isa => 'Git::Repository', lazy_build => 1);

sub _build_git {
    my ($self) = @_;
    return Git::Repository->new();
}


=head1 PAGE TRACKING

Configuration lists the pages to fetch, and the last revision fetched
per page.

TODO: we could populate 'pages' from a category

=cut

sub pages {
    my ($self) = @_;
    my $p = $self->config_for(pages => 'ARRAY');
    die "No pages listed in configuration" unless @$p;
    return @$p;
}


sub page_lastrev {
    my ($self, $pagename, $new_lastrev) = @_;
    my $revs = $self->config->{_page_revs} ||= {};
    $revs->{$pagename} = $new_lastrev if defined $new_lastrev;
    return $revs->{$pagename} || 0;
}


# Destructively takes out all the page content
sub _save_revs {
    my ($self, $pageid, $page) = @_;

    foreach my $rev (@{ $page->{revisions} }) {
        $self->_save_page($page->{title}, $rev);
    }

    $self->config_save;
}


sub _save_page {
    my ($self, $pagename, $props) = @_;

    my $fn = $pagename;
    write_file($fn, { atomic => 1 }, delete $props->{'*'});

    my $author;
    if ($props->{user} =~ m{^[0-9.:]+$}) {
        # user looks like an IP address.

        # exists $props->{anon} # looks promising, but broken in early
        # revs (made with early mediawiki?)
        $author = $self->anon2author($props->{user});
    } else {
        $author = sprintf('%s <%s>', ($props->{user}) x 2);
    }

    my $msg = sprintf
      ("Edit: %s (rev%s) %s\n\n%s",
       $pagename, $props->{revid},
       $props->{comment} || '',
       Dump($props));

    printf("[%s %s] %s\n", $pagename, $props->{revid}, $author);
    $self->git->run(add => $fn);
    $self->git->run
      (commit => '-q',
       -m => $msg,
       -o => $fn,
       '--author' => $author,
       '--date' => $props->{timestamp});

    $self->page_lastrev($pagename, $props->{revid});
}


=head1 HOSTNAME LOOKUP

When users do not log in, we get their IP address.  When this is a web
proxy, we learn nothing; but in a company it is often a one-user
desktop machine.

Do some lookup to make the history more useful.

This can take advantage of the local username-to-hostname mapping I
maintain for ssh aliases, if the configuration file is present.

Beware that looking up historically-recorded IP addresses against the
current DNS is likely to generate surprises.

=cut

has _ptrcache => (is => 'ro', default => sub { {} });
has resolver => (is => 'ro', default => sub { Net::DNS::Resolver->new });
has host2nick => (is => 'rw', isa => 'HashRef', lazy_build => 1);


sub anon2author {
    my ($self, $ip) = @_;
    my $host = $self->ip2host($ip);
    my $nick = $self->host2nick->{$host} || $ip;

    return sprintf('%s <anon@%s>', $nick, $host);
}


sub ip2host { # XXX: IPv6 support?
    my ($self, $ip) = @_;
    my $cache = $self->_ptrcache;
    return $$cache{$ip} ||= do {
        my $q = $self->resolver->search($ip);
        my $rev;
        if ($q) {
            ($rev) = grep { $_->type eq 'PTR' } $q->answer;
            $rev->ptrdname;
        } else {
            warn sprintf("DNS lookup failed (%s) for %s\n", $self->resolver->errorstring, $ip);
            $ip;
        }
    };
}


sub _build_host2nick {
    my ($self) = @_;
    my $fn = "$ENV{HOME}/.ssh/ssh-config.yaml"; # XXX:LOCAL assumptions

    my @cfg = eval { LoadFile($fn) };
    return {} unless 1==@cfg && ref($cfg[0]) eq 'HASH' && $cfg[0]{map};

    my $u2h = $cfg[0]{map};
    my %map = reverse %$u2h;
    my $qualify = $self->config_for('dns_qual', undef, '');
    if ($qualify ne '') {
      foreach my $h (keys %map) {
        next if $h =~ /\./;
        $map{"$h$qualify"} = $map{$h}; # extra entry for FQDN
      }
    }

    return \%map;
}


no Moose;
__PACKAGE__->meta->make_immutable;
