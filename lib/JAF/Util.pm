package JAF::Util;

use strict;
use File::Path ();
use File::Basename ();
use DirHandle ();

### Content

sub trim {
  my $s = shift;
  $s =~ s/^\s+//s;
  $s =~ s/\s+$//s;
  return $s;
}

sub urlify {
  my $urls = '(http|telnet|gopher|file|wais|ftp)';
  my $ltrs = '\w';
  my $gunk = '/#~:.?+=&%@!\-';
  my $punc = '.:?\-';
  my $any  = "${ltrs}${gunk}${punc}";

  my @result = ();
  my @data = @_;

  while ($_ = shift @data) {
    s{
      \b                    # start at word boundary
      (                     # begin $1  {
       $urls     :          # need resource and a colon
       [$any] +?            # followed by on or more
                            #  of any valid character, but
                            #  be conservative and take only
                            #  what you need to....
      )                     # end   $1  }
      (?=                   # look-ahead non-consumptive assertion
       [$punc]*             # either 0 or more punctuation
       [^$any]              #   followed by a non-url char
       |                    # or else
       $                    #   then end of the string
      )
     }{<a target="_blank" href="$1">$1</a>}igox;
    push @result, $_;
  }
  return wantarray ? @result : $result[0];
}

### System

sub mkdir {
  my ($path, $root, $subst) = @_;
  return unless $path;
  if ($root) {
    my @dirs = split '/', $root;
    $dirs[-1] = $subst if $subst;
    $root = join '/', @dirs;
  }
  $path = $root . $path if $root;
  File::Path::mkpath($path) unless -d $path;
  return $path;
}

sub unlink_with_path {
  my $filename = shift;
  my (@files, $rm);

  if(-f $filename) {
    $rm = File::Basename::dirname($filename);
    unlink($filename);
  } elsif(-d $filename) {
    $rm = $filename;
  } else {
    return "Neither a file nor a directory!";
  }

  while (!@files && $rm) {
    opendir DIR, $rm;
    @files = grep !/^\.\.?$/, readdir(DIR);
    closedir DIR;
    unless (@files) {
      rmdir $rm;
      $rm =~ s/\/([^\/]+)$//g;
    }
  }
  return $!;
}

### Date

sub current_date {
  my ($day, $month, $year) = (localtime)[3..5];
  $month++;
  $year += 1900;
  return wantarray ? ($day, $month, $year) : sprintf "%d.%02d.%04d", ($day, $month, $year);
}

# create navigation object
################################################################################
sub get_navigation {
  my ($start, $count, $records_per_page, $navigation_count) = @_;
  
  my $return = { total => $count };
  return $return if($count <= $records_per_page);
  
  for (my ($i,$j) = (0, int -$navigation_count/2); $i < $navigation_count;) {
    last if ($start + $j*$records_per_page > $count);
  
    unless ( $start + $j*$records_per_page  < 0 ) {
      push @{$return->{pages}}, {link => $start + $j*$records_per_page || 1,
                                 selected => !$j,
                                 title =>  ($start + $j*$records_per_page || 1)
                                ."-".
                                 (($start + ($j+1)*$records_per_page - 1 > $count) ? $count : $start + ($j+1)*$records_per_page - 1)};
      $i++
    }
    $j++
  }

  $return->{first} = 1 if($return->{pages}->[0]->{link} > 1);
  $return->{last} = $count - $records_per_page + 1 if($count - $records_per_page >= $return->{pages}->[-1]->{link});
  $return->{prev} = $start - $records_per_page if ($start - $records_per_page > 0);
  $return->{next} = $start + $records_per_page if ($start + $records_per_page <= $count);

  $return;
}

1;
