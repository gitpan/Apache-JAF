package JAF::DBI::Pg;

use JAF::DBI;

our @ISA = qw(JAF::DBI);

sub _insert_sql {
  my ($self, $options) = @_;
  
  my $cols = $options->{cols} || $self->{cols};
  return $self->SUPER::_insert_sql($options) if (!$self->{key} || ref $self->{key});
  foreach (@$cols) {
    return $self->SUPER::_insert_sql($options) if $self->{key} eq $_;
  }
  return "insert into $self->{table} ($self->{key},".(join ',', @{$cols}).") values (nextval('seq_$self->{table}'),".(join ',', map {'?'} @{$cols}).")";
}


1;
