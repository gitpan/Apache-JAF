package Apache::JAF;
use strict;

use 5.6.0;

use Template ();
use Data::Dumper qw(Dumper);
use DirHandle ();

use Apache ();
use Apache::Util ();
use Apache::JAF::Util ();
use Apache::Request ();
use Apache::Constants qw(:common REDIRECT);
use Apache::File ();

our $WIN32 = $^O =~ /win32/i;
our $VERSION = do { my @r = (q$Revision: 0.04 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };

# Constructor
################################################################################
sub new {
  my ($ref, $r) = @_;
  $r = Apache::Request->new($r);

  my $self  = {};
  bless ($self, $ref);

  # r - request (filter-aware)
  $self->{filter} = $r->dir_config('Filter') =~ /^on/i;
  $self->{r} = $self->{filter} ? $r->filter_register() : $r;
  my $prefix = $r->dir_config('Apache_JAF_Prefix');

  # prefix - path|number of subdirs that must be removed from uri
  $prefix = ($prefix =~ /^\/(.*)$/) ? scalar(split '/', $1) : int($prefix);

  # uri - reference to array that contains uri plitted by '/'
  my @uri = split '/', $self->{r}->uri;
  shift @uri if $prefix;
  splice @uri, 0, ($prefix || 1);
  $self->{uri} = \@uri;

  # res - result hash, that passed to the template
  $self->{res} = {};

  # for complex-name-handlers change '_' in handler name to '/' to provide
  # real document tree in Templates folder
  $self->{expand_path} = 1;

  # Level of warnings that will be written to the server's error_log
  # every next level includes all options from previous
  #  0: critical errors only
  #  1: request processing line
  #  2: client request
  #  3: response headers
  #  4: template variables
  #  9: loading additional handlers
  # 10: processed template
  $self->{debug_level} = $self->{r}->dir_config('Apache_JAF_Debug') || 0;

  # Default response status and content-type
  $self->{status} = NOT_FOUND;
  $self->{type} = 'text/html';

  # Default template and includes extensions
  $self->{template_ext} = '.html';
  $self->{include_ext} = '.inc';
  $self->{default_include} = 'default';

  # pre- and post-process templates (without extensions)
  $self->{header} = 'header';
  $self->{footer} = 'footer';
  $self->{pre_chomp} = $self->{post_chomp} = $self->{trim} = 1;

  # Templates folder
  $self->{templates} = $self->{r}->dir_config('Apache_JAF_Templates');

  # Compiled templates folder  
  $self->{compile_dir} = $self->{r}->dir_config('Apache_JAF_Compiled') || '/tmp';

  # This method must be implemented in derived class and must
  # provide $self->{handler} property
  $self->{handler} = $self->setup_handler();
  return undef unless $self->{handler};

  # Log real and uri without prefix
  $self->warn(1, "Starting $ref for " . $self->{r}->uri);
  $self->warn(1, "URI: /" . join '/', @{$self->{uri}});
  $self->warn(2, 'Request: ' . $self->{r}->as_string());

  # Load handlers if $HANDLERS_LOADED flag is unset or 
  # we are in debug mode ($self->{debug_level} > 0)
  my $package = ref $self;
  $self->load_handlers($package) if $self->{debug_level} || !eval('$' . $package . '::HANDLERS_LOADED');

  # {page} key in result hash equals to current handler
  $self->{res}{page} = $self->{handler};

  return $self
}

# Try to load handlers at compile-time
################################################################################
sub import {
  my $package = (caller())[0];
  my $dir = $_[1];

  open OUT, ">>/usr/web/jaf.webzavod.ru/scripts/import.out";
  print OUT "$package => $dir\n\n";
  close OUT;

  load_handlers(undef, $package, $dir) if $dir && $package ne __PACKAGE__;
}

# Load additional handlers
################################################################################
sub load_handlers {
  my ($self, $package, $dir) = @_;
  $dir ||= $self->{r}->dir_config('Apache_JAF_Modules') if $self;

  unless ($dir) {
    $dir = $INC{ do { (my $dummy = $package) =~ s/::/\//g; "$dummy.pm"; } };
    $dir =~ s/\.pm$/\/pages\//;
    undef $dir unless -d $dir;
  }

  eval "\$${package}::HANDLERS_LOADED = 1;";

  my $dh = DirHandle->new($dir);
  foreach my $file ($dh->read) {
    next if $file !~ /\.pm$/;

    local $/;
    open PM, "<$dir/$file";
    my $code = <PM>;
    close PM;
    $code = "package $package; use strict; $code";
    $self && $self->warn(9, "Loading $dir/$file:\n$code");
    eval "$code";
    if ($@) {
      my $err = "$dir/$file - compile error: $@";
      $self && $self->warn(0, $err) || die $err;
      eval "\$${package}::HANDLERS_LOADED = 0;";
    }
  }
}

# ABSTRACT: setup_handler must be implemented in derived 
# class to provide $self->{handler} property mandatory
################################################################################
sub setup_handler { $_[0]->warn(0, 'Abstract method call!') }

# Last modified
################################################################################
sub last_modified { time() }

# Cache
################################################################################
sub cache { undef }

# Log errors and warnings
################################################################################
sub warn { 
  my ($self, $level, $message) = @_;
  my $method = $level ? 'warn' : 'log_error';
  #
  # server_name included in warning string to distinguish different servers in
  # overall error log... (WebZavod default behavior) 
  #
  $self->{r}->$method('[' . $self->{r}->get_server_name() . '] ' . $message) if $self->{debug_level} >= $level;
}

sub _exists {
  my ($self, $dir, $name) = @_;
  if (-f $dir . "/$name") {
    $self->warn(1, 'Ready to process template: /' . $name);
    $self->{template} = $name;
    return 1
  }
  return 0
}

# Process template
################################################################################
sub process_template {
  my ($self) = @_;

  my $rx = $WIN32 ? qr/\:(?!(?:\/|\\))/ : qr/\:/;
  my $tx = "(\\$self->{template_ext})\$";
  foreach (split $rx, $self->{templates}) {
    my $test_name = (join '/', ($self->{handler}, @{$self->{uri}})) . $self->{template_ext};
    last if $self->_exists($_, $test_name);
    $test_name =~ s{$tx}{/index$1};
    last if $self->_exists($_, $test_name);
  }
  $self->{template} ||= ($self->{handler} . $self->{template_ext}, $self->warn(1, 'Ready to process template for handler: ' . $self->{handler}))[0];

  $Template::Config::STASH = 'Template::Stash::XS';

  my $tt = Template->new({
    INCLUDE_PATH => $self->{templates}, 
    PRE_CHOMP => $self->{pre_chomp}, 
    POST_CHOMP => $self->{post_chomp},
    TRIM => $self->{trim},
    ($self->{compile_dir} ? (COMPILE_DIR => $self->{compile_dir}) : ()),
    ($self->{default_include} || $self->{header} ? ('PRE_PROCESS'  => [$self->{default_include} && $self->{default_include} . $self->{include_ext} || (), $self->{header} && $self->{header} . $self->{include_ext} || ()]) : ()),
    ($self->{footer} ? ('POST_PROCESS' => $self->{footer} . $self->{include_ext}) : ())
  });

  $self->warn(4, 'Template variables: ' . Dumper $self->{res});

  my $result;
  $tt->process($self->{template}, $self->{res}, \$result);
  if (my $te = $tt->error()) {
    if ($te =~ /not found/) {
      $self->warn(1, "Template error: $te");
      $self->{status} = NOT_FOUND;
    } else {
      $self->warn(0, "Template error: $te");
      $self->{status} = SERVER_ERROR;
    } 
  } else {
    $self->warn(1, 'Template processed');
    $self->warn(10, $result);
  }

  undef $tt;
  return \$result;
}

# Actual Apache handler
################################################################################
sub handler ($$) {
  my ($self, $r) = @_;
  my $time;
  eval "use Time::HiRes ()";
  $time = Time::HiRes::time() unless $@;

  if (-f $r->filename()) {
    $r->set_handlers(PerlHandler => undef);
    return DECLINED;
  }

  $self = $self->new($r) unless ref($self);
  unless ($self) {
    $self->warn(0, "Can't create handler object!");
    return SERVER_ERROR;
  }

  my $result;
  $self->{status} = $self->site_handler();
  $result = $self->process_template() if $self->{status} == OK && $self->{type} =~ /^text/ && !$self->{r}->header_only;

  if ($self->{status} == OK) {
    $self->{r}->send_http_header($self->{type});
    return $self->{status} if $self->{r}->header_only;

    if ($self->{type} =~ /^text/) {
      #
      # Apache::Filter->print() must(?) be patched for printing referenced scalars
      #
      $self->{r}->print($self->{filter} ? $$result : $result);
    } else {
      #
      # if handler set $self->{type} other than text/(html|plain)
      # then data must be send to client by on_send_... method
      #
      my $method = "on_send_${\($self->{handler})}_data";
      $self->$method(@{$self->{uri}}) if $self->can($method);
    }
  }

  $self->warn(3, 'Response headers: ' . Dumper {($self->{status} == OK) ? $self->{r}->headers_out() : $self->{r}->err_headers_out()});
  $self->warn(1, sprintf 'Request processed in %0.3f sec', Time::HiRes::time() - $time) if $time;

  my $status = $self->{status};
  undef $result;
  undef $self;

  return $status
}

# Global Apache::JAF handler. If you want some stuff before (and|or) after
# running handler you must override it like that:
#
# sub site_handler {
#   my $self = shift;
#
#   [before stuff goes here]
#
#   $self->{status} = $self->SUPER::site_handler(@_);
#
#   [after stuff goes here]
#
#   return $self->{status}
# }
################################################################################
sub site_handler {
  my ($self) = @_;

  my ($method, $last_modified, $cache, $mtime);
  foreach (($method, $last_modified, $cache) = map { $_ . $self->{handler} } qw(do_ last_modified_ cache_)) {
    $_ =~ tr{/}{_} if $self->{expand_path};
  }

  $self->warn(1, "Handler method: $method");

  $mtime = $self->last_modified(@{$self->{uri}});
  $mtime = $self->$last_modified(@{$self->{uri}}) if $self->can($last_modified);
  if ($mtime) {
    $self->{r}->update_mtime($mtime);
    $self->{r}->set_last_modified;
    $self->{status} = $self->{r}->meets_conditions;
    return $self->{status} unless $self->{status} == OK;
  }

  if ($self->can($method)) {
    #
    # process template with handler
    #
    $self->warn(1, "Can do $method: Y");

    my $cstat = $self->cache(@{$self->{uri}});
    $cstat = $self->$cache(@{$self->{uri}}) if $self->can($cache);
    if ($cstat) {
      $self->{status} = $cstat;
    } else {
      $self->{status} = $self->$method(@{$self->{uri}})
    }
    $self->{handler} =~ tr{_}{/} if $self->{expand_path} && $self->{type} =~ /^text/;
    $self->warn(1, 'Content-type: ' . $self->{type});
  } else {
    #
    # process template without handler (defaults variables only, header and footer)
    #
    $self->warn(1, "Can do $method: N");
    $self->{status} = OK unless $self->{status} == SERVER_ERROR;
  }

  return $self->{status};
}

sub param {
  my ($self, $p) = @_;
  my @params = map { $_ = JAF::Util::trim($_); length > 0 ? $_ : undef} ($self->{r}->param($p));
  return $params[0];
} 

sub upload_fh {
  my ($self, $p) = @_;
  if($self->param($p)) {
    my $upl = $self->{r}->upload($p);
    return $upl->fh if($upl && $upl->fh)
  }
  return undef
}

sub default_record_edit {
  my ($self, $tbl, $options) = @_;

  if ($self->{r}->method() eq 'POST' && $self->param('act') eq 'edit') {
    $tbl->update({
      $tbl->{key} => $self->param($tbl->{key}), 
      map {defined $self->{r}->param($_) ? ($_ => $self->param($_)) : $options->{checkbox} && exists $options->{checkbox}{$_} ? ($_ => $options->{checkbox}{$_}) : ()} @{$tbl->{cols}}
    }, $options);
  }
}

sub default_table_edit {
  my ($self, $tbl, $options) = @_;

  if ($self->{r}->method() eq 'POST' && $self->param('act') eq 'edit') {
    for (my $i=1; defined $self->param("$tbl->{key}_$i"); $i++) {
      $tbl->delete({
        $tbl->{key} => $self->param("$tbl->{key}_$i")
      }, $options) if $self->param("dowhat_$i") eq 'del';
      $tbl->update({
        $tbl->{key} => $self->param("$tbl->{key}_$i"), 
        map {defined $self->{r}->param("${_}_$i") ? ($_ => $self->param("${_}_$i")) : $options->{checkbox} && exists $options->{checkbox}{$_} ? ($_ => $options->{checkbox}{$_}) : ()} @{$tbl->{cols}}
      }, $options) if $self->param("dowhat_$i") eq 'upd';
    }
  } elsif ($self->param('act') eq 'add') {
    unless ($tbl->insert({
      map {defined $self->{r}->param($_) ? ($_ => $self->param($_)) : $options->{checkbox} && exists $options->{checkbox}{$_} ? ($_ => $options->{checkbox}{$_}) : ()} @{$tbl->{cols}}
    }, $options)) {
      foreach (@{$tbl->{cols}}) {
        $self->{res}{$_} = $self->param($_);
      }
    }
  }
}

sub default_messages {
  my ($self, $modeller) = @_;
  
  %{$self->{cookies}} = Apache::Cookie->fetch() unless $self->{cookies};
  if ($self->{status} == REDIRECT) {
    my $messages = $modeller->messages();
    if ($messages) {
      Apache::Cookie->new($self->{r},
                          -name => 'messages', 
                          -path => '/',
                          -value => Data::Dumper::Dumper $messages)->bake();
    }
  } elsif ($self->{status} == OK && $self->{type} =~ /^text/ && !$self->{r}->header_only) {
    my $VAR1;
    if (exists $self->{cookies}{messages} && eval $self->{cookies}{messages}->value) {
      $self->{res}{messages} = $VAR1;
      Apache::Cookie->new($self->{r},
                          -name => $self->{res}{messages} ? 'messages' : 'error', 
                          -path => '/', 
                          -value => '')->bake();
    } else {
      $self->{res}{messages} = $modeller->messages();
    }
  } 
}

1;


=head1 NAME

Apache::JAF -- mod_perl and Template-Toolkit web applications framework

=head1 SYNOPSIS

=over 4

=item controller -- mod_perl module that drives your application

 package Apache::JAF::MyJAF;
 use strict;
 use JAF::MyJAF; # optional
 # loading mini-handlers during compile-time
 # this folder will be used by default but you're able to change it
 use Apache::JAF qw(/examples/site/modules/Apache/JAF/MyJAF/pages);
 our @ISA = qw(Apache::JAF);

 # determine handler to call 
 sub setup_handler {
   my ($self) = @_;
   # the page handler for every uri for sample site is 'do_index'
   # you should swap left and right || parts for real application
   my $handler = 'index' || shift @{$self->{uri}};
   return $handler;
 }

 sub site_handler {
   my ($self) = @_;
   # common stuff before handler is called
   $self->{m} = JAF::MyJAF->new(); # create modeller -- if needed
   $self->SUPER::site_handler();
   # common stuff after handler is called
   return $self->{status}
 }
 1;

=item page handler -- controller's method that makes one (or may be several) pages

 sub do_index {
   my ($self) = @_;
   # page handler must fill $self->{res} hash that process with template
   $self->{res}{test} = __PACKAGE__ . 'test';
   # and return Apache constant according it's logic
   return OK;
 }

=item modeller -- module that encapsulates application business-logic

 package JAF::MyJAF;
 use strict;
 use DBI;
 use JAF;
 our @ISA = qw(JAF);

 sub new {
   my ($class, $self) = @_;
   $self->{dbh} = DBI->connect(...);
   return bless $self, $class;
 }
 1;

=item Apache configuration (F<httpd.conf>)

  DocumentRoot /examples/site/data
  <Location />
    <Perl>
      use lib qw(/examples/site/modules);
      use Apache::JAF::MyJAF;
    </Perl>
    SetHandler perl-script
    PerlHandler Apache::JAF::MyJAF
    PerlSetVar Apache_JAF_Templates /examples/site/templates
    # optional -- default value is shown
    PerlSetVar Apache_JAF_Modules /examples/site/modules/Apache/JAF/MyJAF/pages
    # optional -- default value is shown
    PerlSetVar Apache_JAF_Compiled /tmp
  </Location>

=back

=head1 DESCRIPTION

=head2 Introduction

Apache::JAF is designed for creation web applications based on MVC (Model-View-Controller)
concept.

=over 4

=item * 

I<Modeller> is JAF descendant

=item *

I<Controller> is Apache::JAF descendant

=item *

and the I<Viewer> is set of the templates using Template-Toolkit markup syntax

=back

This separation heavily simplifies dynamic site developmet by designers and programmers team.
Each of the programmers working on own part of the project writing separate controller's parts
and designers are working on visual presentation of templates.

=head2 Suggested file structure

Suggested site's on-disk structure is:

  site
   |
   +-- data
   |
   +-- modules
   |
   +-- templates

=over 4

=item I<data> 

document_root for site. All static files such JavaScripts, pictures, CSSs and so on
mus be placed here

=item I<modules>

Storage place for site modules -- must be in C<@INC>'s

=item I<templates>

Here where you have to place your site templates. Framework is designed to reproduce
site-structure in this folder. It's just like document_root for static site.

=back

=head2 Request processing pipeline

The C<Apache::JAF::handler> intercepts every request for specified location, and 
process it own way:

=over 4

=item 1

If requested file exists on disk there is nothing happened. The handle throws request
away with C<DECLINE>.

=item 2

Otherwise instance of Apache::JAF's descendant is created and C<setup_handler> method is called. 
You B<must override> this method and return determined handler name. Usually it's first part of 
uri or just C<index>. Also handlers from C<Apache_JAF_Modules> folder is loaded into package's 
namespace if C<$self-E<gt>{debug_level}> E<gt> 0 or handlers were not loaded during module
compilation.

=item 3

Then goes C<site_handler> calling. If you have common tasks for every handler you can
override it. C<site_handler> calls your own handler. It's name returned by C<setup_handler>. 
Usually this "mini-handler" is I<very> simple. It have to be implemented as package method with
C<do_I<E<lt>handler nameE<gt>>> name. You have to fill C<$self-E<gt>{res}> hash with
result and return Apache constant according to handler's logic (C<OK>, C<NOT_FOUND>, 
C<FORBIDDEN> and so on). The sample is shown in L<"SYNOPSIS">.

=item 4

If result of previous step return OK, and C<$self-E<gt>{type}> property is C<text/*> 
result of processing template is printing to the client. If type of result type is not 
like text, one more method is needed to implement: C<on_send_I<E<lt>handeler nameE<gt>>_data>.
It must print binary data back to the client. This way you may create handlers for
dynamic generation of images, M$ Excel workbooks and any other type of data.

=back

=head2 Apache::JAF descendant methods

=over 4

=item setup_handler

=item site_handler

=back

=head2 Implementing handlers

=head2 Templates structure and syntax

Template for specific handler consists of:

=over 4

=item 1 default.inc

Common C<[% BLOCK %]>s for all site templates. Processed before header and main tamplate.

=item 2 header.inc

Header template. Processed before main handler's template.

=item 3 I<E<lt>handler nameE<gt>>.html

Main handler's template.

=item 4 footer.inc

Footer template. Processed after main handler's template.

=back

Default names and extensions are shown. All of them are configurable in processing 
handler methods. For example you have to disable processing header and footer for 
handler that produces not C<text/*> content.

Templates syntax is described at L<http://www.template-toolkit.org/docs/plain/Manual/>.

=head1 CONFIGURATION

=over 4

=item Apache_JAF_Prefix

Number of uri parts (between slashes) or path that must be removed from request uri.
Useful for implementing dynamic part of almost static site. It's simplifies page handlers
names.

=item Apache_JAF_Templates

Path to templates folder. Several paths may be separated by semicolon.
I<Win32 note>:
This separator works too. Don't get confused with full paths with drive
letters.

=item Apache_JAF_Modules

Path to page handlers folder. By default it's controller location plus C</pages>.

=item Apache_JAF_Compiled

Path to compiled templates folder. Default is C</tmp>.
Saving compiled templates on disk dramatically improves overall site performance.

=item Apache_JAF_Debug

Application's debug level. The amount of debug info written to the Apache error_log.
Ranges from 0 to 10.

 0: critical errors only
 1: request processing line
 2: client request
 3: response headers
 4: template variables
 5-8: not used (for future enchancements)
 9: loading additional handlers
 10: processed template

Also this setting affecting page-handlers loading. If debug level is 0 -- handlers 
are loaded only on server-start. Else handlers loaded on every request. That simplifies
development process but increases request processing time. So it's not good to set 
debug level greater than 0 in production environment.

I<Note:>
This setting is overrided by setting C<$self-E<gt>{debug_level}>.

=back

=head1 SEE ALSO

=over 4

=item * 

B<mod_perl> -- Perl and Apache integration project (L<http://perl.apache.org>)

=item *

B<Template-Toolkit> -- template processing system (L<http://www.tt2.org>)

=item *

F<examples/*> -- sample site driven by Apache::JAF

=item *

L<http://jaf.webzavod.ru> -- Apache::JAF companion website

=back

=head1 AUTHOR

Greg "Grishace" Belenky <greg@webzavod.ru>

=head1 COPYRIGHT

 Copyright (C) 2001-2003 Greg Belenky
 Copyright (C) 2002-2003 WebZavod (http://www.webzavod.ru) programming team

This module is free software; you can redistribute it and/or modify it under the same terms as Perl itself. 

=cut
