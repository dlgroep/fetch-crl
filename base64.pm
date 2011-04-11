#
# Library inspired by the Perl 4 code from base64.pl by A. P. Barrett 
# <barrett@ee.und.ac.za>, October 1993, and subsequent changes by 
# Earl Hood <earl@earlhood.com> to use MIME::Base64 if available.
#

package base64;

my $use_MIMEBase64 = eval { require MIME::Base64; };

sub b64decode
{
    return &MIME::Base64::decode_base64 if $use_MIMEBase64;

    local($^W) = 0; # unpack("u",...) gives bogus warning in 5.00[123]
    use integer;

    my $str = shift;
    $str =~ tr|A-Za-z0-9+=/||cd;            # remove non-base64 chars
    if (length($str) % 4) {
        require Carp;
        Carp::carp("Length of base64 data not a multiple of 4")
    }
    $str =~ s/=+$//;                        # remove padding
    $str =~ tr|A-Za-z0-9+/| -_|;            # convert to uuencoded format
    return "" unless length $str;

    unpack("u", join('', map( chr(32 + length($_)*3/4) . $_,
                        $str =~ /(.{1,60})/gs) ) );
}

sub b64encode
{
    return &MIME::Base64::encode_base64 if $use_MIMEBase64;

    local ($_) = shift;
    local($^W) = 0;
    use integer; # should be faster and more accurate
    
    my $result = pack("u", $_);
    $result =~ s/^.//mg;
    $result =~ s/\n//g;

    $result =~ tr|\` -_|AA-Za-z0-9+/|;
    my $padding = (3 - length($_) % 3) % 3;

    $result =~ s/.{$padding}$/'=' x $padding/e if $padding;
    $result =~ s/(.{1,76})/$1\n/g;
    $result;
}

1;
