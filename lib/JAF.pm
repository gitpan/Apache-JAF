package JAF;

use strict;

# set error
################################################################################
sub error () {
  my ($self, $text) = @_;

  push @{$self->{messages}}, ['error', $text] if $text ne '';
}

# set message
################################################################################
sub message () {
  my ($self, $text) = @_;

  push @{$self->{messages}}, ['message', $text] if $text ne '';
}

# get messages
################################################################################
sub messages () {
  my $self = shift();

  my %hash;
  foreach (@{$self->{messages}}) {
    $hash{"$_->[0]:$_->[1]"}++;
  }
  my $new = [map {[(split ':', $_, 2), $hash{$_}]} keys %hash];
  
  $self->{messages} = [];

  return @$new ? $new : undef;
}

# ???
################################################################################
sub AUTOLOAD {
  my $self = shift;
  my $module = our $AUTOLOAD;
  $module =~ s/.*:://;
  return if $module eq 'DESTROY'; 

  my $pkg = ref($self) . '::' . $module;
  eval("use $pkg");
  
  unless ($@) {
    $self->{$module} ||= "$pkg"->new({ parent => $self, dbh => $self->{dbh} });
    return $self->{$module};
  } else {
    warn $@;
  }
  return undef;
}

1;
