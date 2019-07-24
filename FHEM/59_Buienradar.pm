# This is free and unencumbered software released into the public domain.

#
#  59_Buienradar.pm
#       2018 lubeda
#       2019 ff. Christoph Morrison, <fhem@christoph-jeschke.de>

# Anyone is free to copy, modify, publish, use, compile, sell, or
# distribute this software, either in source code form or as a compiled
# binary, for any purpose, commercial or non-commercial, and by any
# means.

# In jurisdictions that recognize copyright laws, the author or authors
# of this software dedicate any and all copyright interest in the
# software to the public domain. We make this dedication for the benefit
# of the public at large and to the detriment of our heirs and
# successors. We intend this dedication to be an overt act of
# relinquishment in perpetuity of all present and future rights to this
# software under copyright law.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

#  For more information, please refer to <http://unlicense.org/>

# See also https://www.buienradar.nl/overbuienradar/gratis-weerdata


package FHEM::Buienradar;

use strict;
use warnings;
use HttpUtils;
use DateTime;
use JSON;
use List::Util;
use Time::Seconds;
use POSIX;
use Data::Dumper;
use English;
use GPUtils qw(GP_Import GP_Export);
use feature "switch";

our $device;
our $version = '2.1.0';
our @errors;

GP_Export(
    qw(
        Initialize
    )
);

# try to use JSON::MaybeXS wrapper
#   for chance of better performance + open code
eval {
    require JSON::MaybeXS;
    import JSON::MaybeXS qw( decode_json encode_json );
    1;
};

if ($@) {
    $@ = undef;

    # try to use JSON wrapper
    #   for chance of better performance
    eval {

        # JSON preference order
        local $ENV{PERL_JSON_BACKEND} =
            'Cpanel::JSON::XS,JSON::XS,JSON::PP,JSON::backportPP'
            unless ( defined( $ENV{PERL_JSON_BACKEND} ) );

        require JSON;
        import JSON qw( decode_json encode_json );
        1;
    };

    if ($@) {
        $@ = undef;

        # In rare cases, Cpanel::JSON::XS may
        #   be installed but JSON|JSON::MaybeXS not ...
        eval {
            require Cpanel::JSON::XS;
            import Cpanel::JSON::XS qw(decode_json encode_json);
            1;
        };

        if ($@) {
            $@ = undef;

            # In rare cases, JSON::XS may
            #   be installed but JSON not ...
            eval {
                require JSON::XS;
                import JSON::XS qw(decode_json encode_json);
                1;
            };

            if ($@) {
                $@ = undef;

                # Fallback to built-in JSON which SHOULD
                #   be available since 5.014 ...
                eval {
                    require JSON::PP;
                    import JSON::PP qw(decode_json encode_json);
                    1;
                };

                if ($@) {
                    $@ = undef;

                    # Fallback to JSON::backportPP in really rare cases
                    require JSON::backportPP;
                    import JSON::backportPP qw(decode_json encode_json);
                    1;
                }
            }
        }
    }
}

#####################################
sub Initialize($) {

    my ($hash) = @_;

    $hash->{DefFn}       = "FHEM::Buienradar::Define";
    $hash->{UndefFn}     = "FHEM::Buienradar::Undefine";
    $hash->{GetFn}       = "FHEM::Buienradar::Get";
    $hash->{FW_detailFn} = "FHEM::Buienradar::Detail";
    $hash->{AttrList}    = $::readingFnAttributes;
    $hash->{".rainData"} = "";
    $hash->{".PNG"} = "";
    $hash->{REGION} = 'de';
}

sub Detail($$$$) {
    my ( $FW_wname, $d, $room, $pageHash ) =
      @_;    # pageHash is set for summaryFn.
    my $hash = $::defs{$d};

    return if ( !defined( $hash->{URL} ) );

    return
        HTML( $hash->{NAME} )
      . "<p><a href="
      . $hash->{URL}
      . " target=_blank>Raw JSON data (new window)</a></p>";
}

#####################################
sub Undefine($$) {

    my ( $hash, $arg ) = @_;

    ::RemoveInternalTimer( $hash, "Buienradar_Timer" );
    return undef;
}

sub TimeCalc($$) {

    # TimeA - TimeB
    my ( $timeA, $timeB ) = @_;

    my @AtimeA = split /:/, $timeA;
    my @AtimeB = split /:/, $timeB;

    if ( $AtimeA[0] < $AtimeB[0] ) {
        $AtimeA[0] += 24;
    }

    if ( ( $AtimeA[1] < $AtimeB[1] ) && ( $AtimeA[0] != $AtimeB[0] ) ) {
        $AtimeA[1] += 60;
    }

    my $result = ( $AtimeA[0] - $AtimeB[0] ) * 60 + $AtimeA[1] - $AtimeB[1];

    return int($result);
}

###################################
sub Get($$@) {

    my ( $hash, $name, $opt, @args ) = @_;

    return "\"get $name\" needs at least one argument" unless ( defined($opt) );

    given($opt) {
        when ("version") {
            return $version;
        }
    }

    if ( $opt eq "testVal" ) {

        #return  @args;
        return 10**( ( $args[0] - 109 ) / 32 );
    }
    elsif ( $opt eq "rainDuration" ) {
        my $begin = ::ReadingsVal( $name, "rainBegin", "00:00" );
        my $end   = ::ReadingsVal( $name, "rainEnd",   "00:00" );
        if ( $begin ne $end ) {
            return TimeCalc( $end, $begin );
        }
        else {
            return "unknown";
        }
    }

    elsif ( $opt eq "refresh" ) {
        RequestUpdate($hash);
        return "";
    }
    elsif ( $opt eq "startsIn" ) {
        my $begin = ::ReadingsVal( $name, "rainBegin", "unknown" );
        my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
          localtime(time);
        my $result = "";

        if ( $begin ne "unknown" ) {

            $result = TimeCalc( $begin, "$hour:$min" );

            if ( $result < 0 ) {
                $result = "raining";
            }
            return $result;
        }
        return "no rain";
    }
    else {
        return
"Unknown argument $opt, choose one of version:noArg testVal refresh:noArg startsIn:noArg rainDuration:noArg";
    }
}

sub TimeNowDiff {
   my $begin = $_[0];
   my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
   my $result = 0;
   $result = TimeCalc( $begin, "$hour:$min" );
   return $result;
}

#####################################
sub Define($$) {

    my ( $hash, $def ) = @_;

    my @a = split( "[ \t][ \t]*", $def );
    my $latitude;
    my $longitude;

    if ( ( int(@a) == 2 ) && ( ::AttrVal( "global", "latitude", -255 ) != -255 ) )
    {
        $latitude  = ::AttrVal( "global", "latitude",  51.0 );
        $longitude = ::AttrVal( "global", "longitude", 7.0 );
    }
    elsif ( int(@a) == 4 ) {
        $latitude  = $a[2];
        $longitude = $a[3];
    }
    else {
        return
          int(@a)
          . " Syntax: define <name> Buienradar [<latitude> <longitude>]";
    }

    $hash->{STATE} = "Initialized";

    my $name = $a[0];
    $device = $name;

        # alle 2,5 Minuten
    my $interval = 60 * 2.5;

    $hash->{VERSION}                    = $version;
    $hash->{INTERVAL}   = $interval;
    $hash->{LATITUDE}   = $latitude;
    $hash->{LONGITUDE}  = $longitude;
    $hash->{URL}        = undef;
    $hash->{".HTML"}    = "<DIV>";

    ::readingsBeginUpdate($hash);
        ::readingsBulkUpdate( $hash, "rainNow", "unknown" );
        ::readingsBulkUpdate( $hash, "rainDataStart", "unknown");
        ::readingsBulkUpdate( $hash, "rainBegin", "unknown");
        ::readingsBulkUpdate( $hash, "rainEnd", "unknown");
    ::readingsEndUpdate( $hash, 1 );

    Timer($hash);

    return undef;
}

sub Timer($) {
    my ($hash) = @_;
    my $nextupdate = 0;
    ::RemoveInternalTimer( $hash, "Buienradar_Timer" );

    $nextupdate = int( time() + $hash->{INTERVAL} );
    $hash->{NEXTUPDATE} = ::FmtDateTime($nextupdate);
    RequestUpdate($hash);

    ::InternalTimer( $nextupdate, "Buienradar_Timer", $hash );

    return 1;
}

sub RequestUpdate($) {
    my ($hash) = @_;

    #   @todo: https://cdn-secure.buienalarm.nl/api/3.4/forecast.php?lat=51.6&lon=7.3&region=de&unit=mm/u
    $hash->{URL} =
      ::AttrVal( $hash->{NAME}, "BaseUrl", "https://cdn-secure.buienalarm.nl/api/3.4/forecast.php" )
        . "?lat="       . $hash->{LATITUDE}
        . "&lon="       . $hash->{LONGITUDE}
        . '&region='    . 'nl'
        . '&unit='      . 'mm/u';

    my $param = {
        url      => $hash->{URL},
        timeout  => 10,
        hash     => $hash,
        method   => "GET",
        callback => \&ParseHttpResponse
    };

    ::HttpUtils_NonblockingGet($param);
    ::Log3( $hash->{NAME}, 4, $hash->{NAME} . ": Update requested" );
}

sub HTML($;$) {
    my ( $name, $width ) = @_;
    my $hash = $::defs{$name};
    my @values = split /:/, $hash->{".rainData"};

    my $as_html = <<'END_MESSAGE';
<style>

.BRchart div {
  font: 10px sans-serif;
  background-color: steelblue;
  text-align: right;
  padding: 3px;
  margin: 1px;
  color: white;
}
 
</style>
<div class="BRchart">
END_MESSAGE

    $as_html .= "<BR>Niederschlag (<a href=./fhem?detail=$name>$name</a>)<BR>";

    $as_html .= ::ReadingsVal( $name, "rainDataStart", "unknown" ) . "<BR>";
    my $factor =
      ( $width ? $width : 700 ) / ( 1 + ::ReadingsVal( $name, "rainMax", "0" ) );
    foreach my $val (@values) {
        $as_html .=
            '<div style="width: '
          . ( int( $val * $factor ) + 30 ) . 'px;">'
          . sprintf( "%.3f", $val )
          . '</div>';
    }

    $as_html .= "</DIV><BR>";
    return ($as_html);
}

sub ParseHttpResponse($) {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    #Debugging("*** RESULT ***");
    #Debugging(Dumper {param => $param, data => $data, error => $err});

    my %precipitation_forecast;

    if ( $err ne "" ) {
        # Debugging("$name: error while requesting " . $param->{url} . " - $err" );
        $hash->{STATE} = "Error: " . $err . " => " . $data;
    }
    elsif ( $data ne "" ) {
        # Debugging("$name returned: $data");
        my $forecast_data;

        if(defined $param->{'code'} && $param->{'code'} ne "200") {
            push @errors, "HTTP response code is not 200: " . $param->{'code'};
        }

        $forecast_data = eval { $forecast_data = from_json($data) } unless @errors;

        if ($@) {
            push @errors, "Invalid JSON: " . Dumper($@);
        }

        if (@errors) {
            ::Log3($name, 1, "$name had errors while working:\n" . join("\n", @errors));
            $hash->{STATE} = "Error";
            return undef;
        }

        # @todo this here is the problem
        my @precip = @{$forecast_data->{"precip"}} unless @errors;

        Debugging(Dumper @precip);
        Debugging(Dumper @errors);

        $hash->{DATA} = join(", ", @precip);

        if (scalar @precip > 0) {
            my $rainLaMetric    = join(',', map {$_ * 1000} @precip[0..11]);
            my $rainTotal       = List::Util::sum @precip;
            my $rainMax         = List::Util::max @precip;
            my $rainStart       = undef;
            my $rainEnd         = undef;
            my $dataStart       = $forecast_data->{start};
            my $dataEnd         = $dataStart + (scalar @precip) * 5 * ONE_MINUTE;
            my $forecast_start  = $dataStart;
            my $rainNow         = undef;

            for (my $precip_index = 0; $precip_index < scalar @precip; $precip_index++) {
                my $start    = $forecast_start + $precip_index * 5 * ONE_MINUTE;
                my $end      = $start + 5 * ONE_MINUTE;
                my $precip   = $precip[$precip_index];

                if (!$rainStart and $precip > 0) {
                    $rainStart  = $start;
                }

                if (!$rainEnd and $rainStart and $precip == 0) {
                    $rainEnd    = $start;
                }

                if (!$rainNow and gmtime ~~ [$start..$end]) {
                    $rainNow    = $precip;
                }

                $precipitation_forecast{$start} = {
                    'start'        => $start,
                    'end'          => $end,
                    'precipiation' => $precip,
                };
            }

            $hash->{STATE} = sprintf( "%.3f", $rainNow );

            ::readingsBeginUpdate($hash);
                ::readingsBulkUpdate( $hash, "rainTotal", sprintf( "%.3f", $rainTotal) );
                ::readingsBulkUpdate( $hash, "rainAmount", sprintf( "%.3f", $rainTotal) );
                ::readingsBulkUpdate( $hash, "rainNow", sprintf( "%.3f mm/h", $rainNow ) );
                ::readingsBulkUpdate( $hash, "rainLaMetric", $rainLaMetric );
                ::readingsBulkUpdate( $hash, "rainDataStart", strftime "%R", localtime $dataStart);
                ::readingsBulkUpdate( $hash, "rainDataEnd", strftime "%R", localtime $dataEnd );
                ::readingsBulkUpdate( $hash, "rainMax", sprintf( "%.3f", $rainMax ) );
                ::readingsBulkUpdate( $hash, "rainBegin", (($rainStart) ? strftime "%R", localtime $rainStart : 'unknown'));
                ::readingsBulkUpdate( $hash, "rainEnd", (($rainEnd) ? strftime "%R", localtime $rainEnd : 'unknown'));
            ::readingsEndUpdate( $hash, 1 );
        }
    }
}

sub Debugging {
    local $OFS = ", ";
    ::Debug("@_") if ::AttrVal("global", "verbose", undef) eq "4" or ::AttrVal($device, "debug", 0) eq "1";
}


1;

=pod

=item helper
=item summary Rain prediction
=item summary_DE Regenvorhersage auf Basis des Wetterdienstes buienradar.nl

=begin html



=end html

=begin html_DE



=end html_DE

=cut

=for :application/json;q=META.json 59_Buienradar.pm
{
    "abstract": "FHEM module for precipiation forecasts basing on buienradar.nl",
    "x_lang": {
        "de": {
            "abstract": "FHEM-Modul f&uuml;r Regen- und Regenmengenvorhersagen auf Basis von buienradar.nl"
        }
    },
    "keywords": [
        "Buienradar",
        "Precipiation",
        "Rengenmenge",
        "Regenvorhersage",
        "hoeveelheid regen",
        "regenvoorspelling",
        "Niederschlag"
    ],
    "release_status": "development",
    "license": "Unlicense",
    "version": "2.1.0",
    "author": [
        "Christoph Morrison <post@christoph-jeschke.de>"
    ],
    "resources": {
        "homepage": "https://github.com/fhem/mod-Buienradar/",
        "x_homepage_title": "Module homepage",
        "license": [
            "https://github.com/fhem/mod-Buienradar/blob/master/LICENSE"
        ],
        "bugtracker": {
            "web": "https://github.com/fhem/mod-Buienradar/issues"
        },
        "repository": {
            "type": "git",
            "url": "https://github.com/fhem/mod-Buienradar.git",
            "web": "https://github.com/fhem/mod-Buienradar.git",
            "x_branch": "master",
            "x_development": {
                "type": "git",
                "url": "https://github.com/fhem/mod-Buienradar.git",
                "web": "https://github.com/fhem/mod-Buienradar/tree/development",
                "x_branch": "development"
            },
            "x_filepath": "",
            "x_raw": ""
        },
        "x_wiki": {
            "title": "Buienradar",
            "web": "https://wiki.fhem.de/wiki/Buienradar"
        }
    },
    "x_fhem_maintainer": [
        "jeschkec"
    ],
    "x_fhem_maintainer_github": [
        "christoph-morrison"
    ],
    "prereqs": {
        "runtime": {
            "requires": {
                "FHEM": 5.00918799,
                "perl": 5.10,
                "Meta": 0,
                "JSON": 0
            },
            "recommends": {
            
            },
            "suggests": {
            
            }
        }
    }
}
=end :application/json;q=META.json
