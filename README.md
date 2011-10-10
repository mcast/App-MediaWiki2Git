# NAME

App::MediaWiki2Git - copy MediaWiki page history into a Git repository# DESCRIPTION

This is a workaround for the lack of an "annotate" (aka. "blame")
feature in the MediaWiki we use locally.

It operates using configuration in and upon a Git repository at the
current directory.



# CONFIGURATION

By default, it expects `mw2git.yaml` to exist in the current directory.

This should contain one hash (dictionary), whose entries are used to
configure parts of this package.

This configuration may be extended and (atomically) replaced as
fetching progresses.

XXX: errors during a run can leave the config out of sync with the committed pages
so page revisions may get committed again.  One solution would be to
`reset --hard` to the last config save commit.  This could be
automated, at some cost to the principle of least surprise.



# MEDIAWIKI INTERFACE

The config key `mediawiki` should contain a hash suitable for passing
to L<MediaWiki::API/new>.

One entry for `api_url`, constructed by replacing the `index.php` in
"http://...server.../wiki/index.php" with `api.php` should be enough.

# GIT INTERFACE

Uses [Git::Repository](http://search.cpan.org/perldoc?Git::Repository) to drive Git upon the current directory.

It is assumed that the previous requirement for the existence of the
configuration file is enough of a sanity check, to prevent messing
with any other Git repositories' history.

You need to initialise the empty repository directory with a suitable
configuration file.

# PAGE TRACKING

Configuration lists the pages to fetch, and the last revision fetched
per page.

TODO: we could populate 'pages' from a category

# HOSTNAME LOOKUP

When users do not log in, we get their IP address.  When this is a web
proxy, we learn nothing; but in a company it is often a one-user
desktop machine.

Do some lookup to make the history more useful.

This can take advantage of the local username-to-hostname mapping I
maintain for ssh aliases, if the configuration file is present.

Beware that looking up historically-recorded IP addresses against the
current DNS is likely to generate surprises.