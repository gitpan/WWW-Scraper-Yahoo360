#
# Ignorant Yahoo 360 blog scraper (blog.360.yahoo.com)
#
# $Id$

package WWW::Scraper::Yahoo360;

use strict;
use warnings;

use Carp           ();
use Date::Parse    ();
use File::Slurp    ();
use HTTP::Date     ();
use JSON::XS       ();
use WWW::Mechanize ();

use constant BLOG_URL   => 'http://blog.360.yahoo.com/blog/';
use constant LOGIN_FORM => 'login_form';
use constant LOGIN_URL  => q{https://login.yahoo.com/config/login_verify2?.intl=us&.done=http%3A%2F%2Fblog.360.yahoo.com%2Fblog%2F%3F.login%3D1&.src=360};

our $VERSION = '0.01';

sub new {
    my ($class, $args) = @_;
    $class = ref $class || $class || __PACKAGE__;
    my $self = $args;
    bless $self, $class;
}

sub blog_info {
    my ($self, $blog_page) = @_;

    if (! $blog_page) {
        $blog_page = $self->blog_main_page();
    }

    # Get sharing level
    #
    # <p class="footnote">Your blog can be seen by  <strong>Public</strong>
    #
    my $sharing = q{};
    if ($blog_page =~ m{Your blog can be seen by  <strong>([\w\s]+)</strong>}m) {
        $sharing = lc $1; 
    }

    # Get title
    my $title = q{};
    if ($blog_page =~ m{<h3>([^<]+)<span class="view-toggle">Full Post View}m) {
        $title = $1;
    }

    # Get number of posts
    #
    # <span><em>1 - 5</em> of <em class="limit">13</em> ...
    my $start =
    my $end   =
    my $count = 0;

    if ($blog_page =~ m{<span><em>(\d+) \- (\d+)</em> of <em class="limit">(\d+)</em>}m) {
        $start = $1;
        $end   = $2;
        $count = $3;
    }

    my $link = q{};
    if ($blog_page =~ m{<a href="([^"]+)" class="selected">My Blog</a>}) {
        $link = $1;
    }

    $title =~ s{^\s+}{};
    $title =~ s{\s+$}{};

    return {
        sharing => $sharing,
        title   => $title,
        start   => $start,
        end     => $end,
        count   => $count,
        link    => $link,
        lastBuildDate => HTTP::Date::time2str(),
        language => 'en-us',
    };

}

sub blog_main_page {
    my ($self) = @_;
    my $mech = $self->mech();
    $mech->get(BLOG_URL);
    if ($mech->success()) {
        return $mech->content();
    }
    Carp::croak("Failed to retrieve blog main page");
}

sub blog_page_url {
    my ($self, $link, $start, $per_page, $count) = @_;
    my $url = $link;
    my $last = $start + $per_page - 1;
    if ($last > $count) { $last = $count }
    $url .= '&l=' . $start;
    $url .= '&u=' . $last;
    $url .= '&mx=' . $count;
    $url .= '&lmt=' . $per_page;
    return $url;
}

sub login {
    my ($self) = @_;

    my $user = $self->{username};
    my $pass = $self->{password};

    my $mech = $self->mech();

    $mech->get(LOGIN_URL);

    $mech->submit_form(
        form_name => LOGIN_FORM,
        fields    => {
            login => $user,
            passwd => $pass,
            '.persistent' => 'y',
        }, 
        button    => '.save',
    );

    return $mech->success();
}

sub dump {
    my ($self) = @_;
    print $self->mech->content();
}

sub get_blog_comments {
    my ($self, $posts) = @_;

    if (! $posts) {
        return;
    }

    my @comments;

    for my $post (@{$posts}) {

        # No comments, don't fetch them
        if ($post->{comments} == 0) {
            next;
        }

        #print qq{Found $post->{comments} comments for blog post "$post->{title}"\n};

        if (my $post_comm = $self->get_blogpost_comments($post)) {
            push @comments, @{ $post_comm };
        }

    }

    return \@comments;
}

sub get_blogpost_comments {
    my ($self, $post, $page) = @_;

    # If we didn't get a pre-saved html page, get it now
    if (! $page) {
        $self->mech->get($post->{link});
        $page = $self->mech->success
            ? $self->mech->content()
            : q{};
    }

    if (! $page) {
        warn "ERROR fetching blogpost comments for $post->{title}\n";
        return;
    }

    my @comments;

    while ($page =~ m{<li class="user-name"><a href="([^"]+)" title="([^"]+)">}mg) {

        my $comment = {
            'user-profile' => $1,
            username => $2,
            link => $post->{link},
        };

        # Comments can span multiple lines
        # but are always enclosed between <p class="comment"> and </p>
        if ($page =~ m{<p class="comment">(.*?)</p>}sg) {
            $comment->{comment} = $1;
            $comment->{comment} =~ s{^\s+}{};
            $comment->{comment} =~ s{\s+$}{};
        }

        if ($page =~ m{<p class="datestamp">([^<]+)\s*<}mg) {
            $comment->{date} = $1;
            $comment->{date} =~ s{^\s+}{};
            $comment->{date} =~ s{\s+$}{};
            $comment->{date} = $self->parse_date($comment->{date});
        }

        push @comments, $comment;
    }

    return \@comments;
}

sub get_blog_posts {
    my ($self, $blog_page) = @_;

    $blog_page ||= $self->blog_main_page();
    my $blog_info = $self->blog_info($blog_page);

    my $link  = $blog_info->{link};
    my $start = $blog_info->{start};
    my $end   = $blog_info->{end};
    my $count = $blog_info->{count};
    my $per_page = $end - $start + 1;

    my @posts = ();

    for (my $n = $start; $n < $start + $count; ) {

        #print "Reading post n. $n\n";

        # Fetch next page and continue
        if ($n >= $end) {

            my $next_page_url = $self->blog_page_url(
                $link, $end + 1, $per_page, $count
            );

            $end += $per_page;

            $self->mech->get($next_page_url);
            #warn "Next url is: $next_page_url\n";

            $blog_page = $self->mech->content();
            if (! $blog_page) {
                warn "Failed to read url: $next_page_url\n";
                last;
            }

        }

        while ($blog_page =~ m{<dt class="post-head">([^<]+)</dt>}gm) {
           
            # Blog post title 
            my $title = $1;
            my $post = { title => $1 };

            #print "    [$n] Title: $title\n";

            # Blog post content
            if ($blog_page =~ m{<div class="content-wrapper">(.*?)</div>}gm) {
                $post->{description} = $1;
                #print "    [$n] Body: ", substr($1, 0, 30), '... ', "\n";
            }

            # Tags
            if ($blog_page =~ m{<form><input type="hidden" name="tagslist" value="([^"]*)"}gm) {
                $post->{tags} = $1;
                #print "    [$n] Tags: $1\n";
            }

            # Date of post
            if ($blog_page =~ m{<span>([^<]+)<a href="[^"]+">Edit</a>}gm) {
                $post->{pubDate} = HTTP::Date::time2str($self->parse_date($1));
                #print "    [$n] Date: $1\n";
            }

            # Permanent link
            if ($blog_page =~ m{<a href="([^"]+)">Permanent Link</a>}gm) {
                $post->{link} = $1;
                #print "    [$n] Permalink: $1\n";
            }

            # No. of comments
            if ($blog_page =~ m{<a href="[^"]+">(\d+) Comments?</a>}gm) {
                $post->{comments} = $1;
            }

            push @posts, $post;

            $n++;

        }

    }

    return \@posts;

}

sub mech {
    my ($self) = @_;
    if (! exists $self->{_mech}) {
        $self->{_mech} = WWW::Mechanize->new();
    }
    return $self->{_mech};
}

sub parse_date {
    my ($self, $date) = @_;

    $date =~ s{^\s+}{};
    $date =~ s{\s+$}{};

    if ($date =~ m{^ (\w{3})\w+ \s (\w{3})\w+ \s (\d+), \s (\d+) \s - \s (\d+):(\d+)([ap]m) \s \((.*)\) \s* $}x) {
        my $dow   = $1;
        my $month = $2;
        my $day   = $3;
        my $year  = $4;
        my $hours = $5;
        my $mins  = $6;
        my $ampm  = uc $7;
        my $tz    = uc $8;

        # Indochina time zone is not recognized by Date::Parse
        if ($tz eq 'ICT') {
            $tz = 'UTC+07';
        }

        if ($ampm eq 'pm') {
            $hours += 12;
            if ($hours > 23) { $hours -= 24 }
        }

        my $time = "$hours:$mins:00";

        # Wed, 16 Jun 94 07:29:35 CST
        $date = "$day $month $year $time $tz"; 
    }

    $date = Date::Parse::str2time($date);

    return $date;
}

1;

__END__

# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

WWW::Scraper::Yahoo360 - Perl extension for blah blah blah

=head1 SYNOPSIS

  use WWW::Scraper::Yahoo360;

  my $y360 = WWW::Scraper::Yahoo360->new({
      username => 'myusername',
      password => 'password',
  });

  my $blog_info = $y360->blog_info();
  my $posts     = $y360->get_blog_posts();

  my $comments  = $y360->get_blog_comments();

=head1 DESCRIPTION

Ignorant web scraper, based on WWW::Mechanize, that connects to your
Yahoo 360 account and tries to fetch the blog posts and comments 
you had on their service.

If it breaks, well... it's a scraper.

This module is used on the My Opera Community, L<http://my.opera.com>,
to import Yahoo 360 existing blogs into My Opera blog service.

=head2 EXPORT

None by default.

=head1 AUTHOR

cosimo, E<lt>cosimo@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009 by Cosimo Streppone, L<cosimo@cpan.org>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut
