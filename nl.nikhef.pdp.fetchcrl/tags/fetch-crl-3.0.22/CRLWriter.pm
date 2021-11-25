#
# @(#)$Id$
#
# ###########################################################################
#
#
# Syntax:
#   CRLWriter->new( [name [,index]] );
#   CRLWriter->setTA( trustanchor );
#   CRLWriter->setIndex( index );
#
package CRLWriter;
use strict;
use File::Basename;
use File::Temp qw/ tempfile /;
require OSSL and import OSSL unless defined &OSSL::new;
require base64 and import base64 unless defined &base64::b64encode;
use vars qw/ $log $cnf /;

sub new {
  my $obref = {}; bless $obref;
  my $self = shift;
  $self = $obref;
  my $name = shift;
  my $index = shift;

  $self->setTA($name) if defined $name;
  $self->setIndex($name) if defined $index;

  return $self;
}


sub getName($) {
  my $self = shift;
  return 0 unless defined $self;
  return $self->{"ta"}->getAnchorName;
}

sub setTA($$) {
  my $self = shift;
  my ($ta) = shift;
  return 0 unless defined $ta and defined $self;
  $ta->{"anchorname"} or 
    $::log->err("CRLWriter::setTA called without uninitialised trust anchor") 
    and return 0;
  $self->{"ta"} = $ta;
  return 1;
}

sub setIndex($$) {
  my $self = shift;
  my ($index) = shift;
  return 0 unless defined $self;
  $self->{"ta"} or
    $::log->err("CRLWriter::setIndex called without a loaded TA") and 
    return 0;
  my $ta = $self->{"ta"};

  $ta->{"crlurls"} or 
    $::log->err("CRLWriter::setIndex called with uninitialised TA") and 
    return 0;

  ! defined $index and delete $self->{"index"} and return 1;

  $index < 0 and
    $::log->err("CRLWriter::setIndex called with invalid index $index") and 
    return 0;
  $index > $#{$ta->{"crlurls"}} and
    $::log->err("CRLWriter::setIndex index $index too large") and 
    return 0;

  $self->{"index"} = $index;

  return 1;
}

sub updatefile($$%) {
  my $file = shift;
  my $content = shift;
  my %flags = @_;
  $content or return undef;
  $file or
    $::log->err("Cannot write content to undefined path") and return undef;

  my ( $basename, $path, $suffix ) = fileparse($file);

  # get content and do a comparison. If data identical, touch only
  # to update mtime (other tools like NGC Nagios use this mtime semantics)
  #
  my $olddata; 
  my $mytime;
  -f $file and do { 
    $mytime = (stat(_))[9];
    {
      open OLDFILE,'<',$file or 
        $::log->err("Cannot make backup of $file: $!") and return undef;
      binmode OLDFILE; local $/;
      $olddata = <OLDFILE>; close OLDFILE;
    }
  };
  if ( $flags{"BACKUP"} and $olddata ) {
    if ( -w $path ) {
      -e "$file~" and ( unlink "$file~" or
        $::log->warn("Cannot remove old backup $file~: $!") and return undef);
      if (open BCKFILE,'>',"$file~" ) {
        print BCKFILE $olddata;
        close BCKFILE;
        utime $mytime,$mytime, "$file~";
      } else {
        $::log->warn("Cannot reate backup $file~: $!");
      }
    } else {
      $::log->warn("Cannot make backup, $path not writable");
    }
  }

  defined $olddata  and $olddata eq $content and do {
    $::log->verb(4,"$file unchanged - touch only");
    utime time,time,$file and return 1;
    $::log->warn("Touch of $file failed, CRL unmodified");
    return 0;
  };

  # write new CRL to file ($file in $path) - attempting to do
  # an atomic action to prevent a reace condition with clients
  # but do not insist if the $path is not writable for new files
  my $tmpcrlmode=((stat $file)[2] || 0644) & 07777;
  $::log->verb(5,"TMP file for $file mode $tmpcrlmode");
  my $tmpcrl = File::Temp->new(DIR => $path, SUFFIX => '.tmp', 
                               PERMS => $tmpcrlmode, UNLINK => 1);
  if ( defined $tmpcrl ) { # we could create a tempfile next to current 
    print $tmpcrl $content or 
      $::log->err("Write to $tmpcrl: $!") and return undef;
    # atomic move, but no need to restore from backup on failure
    # and the unlink on destroy is implicit
    chmod $tmpcrlmode,$tmpcrl or
      $::log->err("chmod on $tmpcrl (to $tmpcrlmode): $!") and 
      return undef;
    rename($tmpcrl, $file) or 
      $::log->err("rename $tmpcrl to $file: $!") and return undef;
    # file was successfully renamed, so nothing left to unlink
    $tmpcrl->unlink_on_destroy( 0 );
  } elsif ( open FH,'>',$file ) { 
    # no adjecent write possible, fall back to rewrite
    print FH $content or
      $::log->err("Write to $file: $!") and return undef;
    close FH or 
      $::log->err("Close on write of $file: $!") and return undef;
  } else { # something went wrong in opening the file for write,
           # so try and restore backup if that was selected
    $::log->err("Open for write of $file: $!");
    $flags{"BACKUP"} and ! -s "$file" and -s "$file~" and do { 
      #file has been clobbed, but backup OK
      unlink "$file" and link "$file~","$file" and unlink "$file~" or
        $::log->err("Restore of backup $file failed: $!");
    };
    return undef;
  }
  return 1;
}

sub writePEM($$$$) {
  my $self = shift;
  my $idx = shift;
  my $data = shift;
  my $ta = shift;
  defined $idx and $data and $ta or 
    $::log->err("CRLWriter::writePEM: missing index or data") and return 0;

  my $output = $::cnf->{_}->{"output"};
  $output = $::cnf->{_}->{"output_pem"} if defined $::cnf->{_}->{"output_pem"};
  $output and -d $output or 
    $::log->err("PEM target directory $output invalid") and return 0;

  my $filename = "$output/".$ta->{"nametemplate_pem"};
  $filename =~ s/\@R\@/$idx/g;

  my %flags = ();
  $::cnf->{_}->{"backups"} and $flags{"BACKUP"} = 1;

  if ($data !~ /\n$/sm) {
    $::log->verb(5,"Appending newline to short PEM file",$filename);
    $data="$data\n";
  }

  $::log->verb(3,"Writing PEM file",$filename);
  &updatefile($filename,$data,%flags) or return 0;
  return 1;
}

sub writeDER($$$$) {
  my $self = shift;
  my $idx = shift;
  my $data = shift;
  my $ta = shift;
  defined $idx and $data and $ta or 
    $::log->err("CRLWriter::writeDER: missing index or data") and return 0;

  my $output = $::cnf->{_}->{"output"};
  $output = $::cnf->{_}->{"output_der"} if defined $::cnf->{_}->{"output_der"};
  $output and -d $output or 
    $::log->err("DER target directory $output invalid") and return 0;

  my $filename = "$output/".$ta->{"nametemplate_der"};
  $filename =~ s/\@R\@/$idx/g;

  my %flags = ();
  $::cnf->{_}->{"backups"} and $flags{"BACKUP"} = 1;

  my $openssl=OSSL->new();
  my ($der,$errors) = $openssl->Exec3($data,qw/crl -inform PEM -outform DER/);
  $errors or not $der and
    $::log->err("Data count not be converted to DER: $errors") and return 0;

  $::log->verb(3,"Writing DER file",$filename);
  &updatefile($filename,$der,%flags) or return 0;
  return 1;
}

sub writeOpenSSL($$$$) {
  my $self = shift;
  my $idx = shift;
  my $data = shift;
  my $ta = shift;
  defined $idx and $data and $ta or 
    $::log->err("CRLWriter::writeOpenSSL: missing index, data or ta") and 
    return 0;

  my $output = $::cnf->{_}->{"output"};
  $output = $::cnf->{_}->{"output_openssl"} if 
    defined $::cnf->{_}->{"output_openssl"};
  $output and -d $output or 
    $::log->err("OpenSSL target directory $output invalid") and return 0;

  my $openssl=OSSL->new();

  # guess the hash name or names from OpenSSL
  # if mode is dual (and OpenSSL1 installed) write two files
  my $opensslversion = $openssl->getVersion() or return 0;

  my ($cmddata,$errors);
  my @hashes = ();
  if ( $opensslversion ge "1" and $::cnf->{_}->{"opensslmode"} eq "dual" ) {
    $::log->verb(5,"OpenSSL version 1 dual-mode enabled");
    # this mode needs the ta cafile to get both hashes, since these
    # can only be extracted by the x509 subcommand from a CA ...
    ($cmddata,$errors) = $openssl->Exec3(undef,
       qw/x509 -noout -subject_hash -subject_hash_old -in/, 
       $ta->{"cafile"}[0]);
    $cmddata or 
      $::log->err("OpenSSL cannot extract hashes from",$ta->{"cafile"}[0]) and 
      return 0;
    @hashes = split(/[\s\n]+/,$cmddata);
  } else {
    $::log->verb(5,"OpenSSL version 1 single-mode or pre-1.0 style");
    ($cmddata,$errors) = $openssl->Exec3($data,qw/crl -noout -hash/);
    $cmddata or 
      $::log->err("OpenSSL cannot extract hashes from CRL for",
                  $ta->{"alias"}.'/'.$idx
      ) and 
      return 0;
    @hashes = split(/[\s\n]+/,$cmddata);
  }

  my %flags = ();
  $::cnf->{_}->{"backups"} and $flags{"BACKUP"} = 1;

  foreach my $hash ( @hashes ) {
    my $filename = "$output/$hash.r$idx";
    $::log->verb(3,"Writing OpenSSL file",$filename);
    &updatefile($filename,$data,%flags) or return 0;
  }
  return 1;
}

sub writeNSS($$$$) {
  my $self = shift;
  my $idx = shift;
  my $data = shift;
  my $ta = shift;
  defined $idx and $data and $ta or 
    $::log->err("CRLWriter::writeNSS: missing index, data or ta") and return 0;

  my $output = $::cnf->{_}->{"output"};
  $output = $::cnf->{_}->{"output_nss"} if defined $::cnf->{_}->{"output_nss"};
  $output and -d $output or 
    $::log->err("NSS target directory $output invalid") and return 0;

  my $dbprefix="";
  $dbprefix = $::cnf->{_}->{"nssdbprefix"} 
    if defined $::cnf->{_}->{"nssdbprefix"};

  my $filename = "$output/$dbprefix";

  # the crlutil tool requires the DER formatted cert in a file
  my $tmpdir = $::cnf->{_}->{exec3tmpdir} || $ENV{"TMPDIR"} || '/tmp';
  my ($derfh,$dername) = tempfile("fetchcrl3der.XXXXXX",
                                  DIR=>$tmpdir, UNLINK=>1);
  (my $b64data = $data) =~ s/-[^\n]+//gm;
  $b64data =~ s/\s+//gm;
  print $derfh  base64::b64decode($b64data); # der is decoded PEM :-)

  my $cmd = "crlutil -I -d \"$output\" -P \"$dbprefix\" ";
  $::cnf->{_}->{nonssverify} and $cmd .= "-B ";
  $cmd .= "-n ".$ta->{"alias"}.'.'.$idx." ";
  $cmd .= "-i \"$dername\"";
  my $result = `$cmd 2>&1`;
  unlink $dername;
  if ( $? != 0 ) {
    $::log->err("Cannot update NSSDB filename: $result");
  } else {
    $::log->verb(3,"WriteNSS: ".$ta->{"alias"}.'.'.$idx." added to $filename");
  }
  
  return 1;
}


sub writeall($) {
  my $self = shift;
  return 0 unless defined $self;
  $self->{"ta"} or
    $::log->err("CRLWriter::setIndex called without a loaded TA") and 
    return 0;
  my $ta = $self->{"ta"};
  $ta->{"crlurls"} or 
    $::log->err("CRLWriter::setIndex called with uninitialised TA") and 
    return 0;

  $::log->verb(2,"Writing CRLs for",$ta->{"anchorname"});

  my $completesuccess = 1;
  for ( my $idx = 0 ; $idx <= $#{$ta->{"crl"}} ; $idx++ ) {
    $ta->{"crl"}[$idx]{"pemdata"} or 
      $::log->verb(3,"Ignored CRL $idx skipped") and
        next; # ignore empty crls, leave these in place

    my $writeAttempt = 0;
    my $writeSuccess = 0;

    ( grep /^pem$/, @{$::cnf->{_}->{formats_}} ) and ++$writeAttempt and
      $writeSuccess += $self->writePEM($idx,$ta->{"crl"}[$idx]{"pemdata"},$ta);

    ( grep /^der$/, @{$::cnf->{_}->{formats_}} ) and ++$writeAttempt and
      $writeSuccess += $self->writeDER($idx,$ta->{"crl"}[$idx]{"pemdata"},$ta);

    ( grep /^openssl$/, @{$::cnf->{_}->{formats_}} ) and ++$writeAttempt and
      $writeSuccess += $self->writeOpenSSL($idx,
                                           $ta->{"crl"}[$idx]{"pemdata"},$ta);

    ( grep /^nss$/, @{$::cnf->{_}->{formats_}} ) and ++$writeAttempt and
      $writeSuccess += $self->writeNSS($idx,$ta->{"crl"}[$idx]{"pemdata"},$ta);

    if ( $writeSuccess == $writeAttempt ) {
      $::log->verb(4,"LastWrite time (mtime) set to current time");
      $ta->{"crl"}[$idx]{"state"}{"mtime"} = time;
    } else {
      $::log->warn("Partial updating ($writeSuccess of $writeAttempt) for",
                   $ta->{"anchorname"},
                   "CRL $idx: mtime not updated");
    }
    $completesuccess &&= ($writeSuccess == $writeAttempt);
  }

  return $completesuccess;
}

1;
