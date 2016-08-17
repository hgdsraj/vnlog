#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;

use feature qw(say state);


my $usage = "$0 [--dumpindices] col0 col1 col2 f(col0) g(col1)....\n";
if(! @ARGV)
{
    die $usage;
}

my %options;
GetOptions(\%options,
           "dumpindices!",
           "help") or die($usage);

if( defined $options{help} )
{
    print $usage;
    exit 0;
}

# useful for realtime plots
autoflush STDOUT;

my @cols_want = @ARGV;

# if no columns requested, just print everything
if(!@cols_want)
{
    while(<STDIN>)
    { print; }
}

# script to read intersense logs and to only select particular columns
my @indices = ();


my @transforms;

while(<STDIN>)
{
    if(/^##/p)
    {
        print;
        next;
    }

    if( !@indices && /^#/p )
    {
        chomp;

        # we got a legend line
        my @cols_all = split ' ', ${^POSTMATCH}; # split the field names (sans the #)
        my @colnames_output;


        # grab all the column indices
        foreach my $col (@cols_want)
        {
            # First off, I look for any requested functions. These all look like
            # "f(x)" and may be nested. f(g(h(x))) is allowed.

            my @funcs;
            while($col =~ /^           # start
                           ( [^\(]+ )  # Function name. Non-( characters
                           \( (.+) \)  # Function arg
                           $           # End
                          /x)
            {
                unshift @funcs, $1;
                $col = $2;
            }

            # OK. Done looking for transformations. Let's match the columns

            my @indices_here;
            my $accept = sub
            {
                push @colnames_output, @cols_all[@indices_here];

                if( @funcs )
                {
                    # This loop is important. It is possible to push it to later
                    # by doing this instead:
                    #
                    #   push @transforms, [\@indices_here, parse_transform_funcs(@funcs) ];
                    #
                    # but then all of @indices_here will get a single
                    # transformation subroutine object, and all of its internal
                    # state will be shared, which is NOT what you want. For
                    # instance if we're doing rel(.*time) or something, then the
                    # initial timestamp would be shared. This is wrong.
                    #
                    # The indices here index the OUTPUT columns list
                    foreach my $idx (0..$#indices_here)
                    {
                        push @transforms, [$idx + @indices, parse_transform_funcs(@funcs) ];

                        $colnames_output[$idx + @indices] =
                          join('', map { "$_("} reverse @funcs) .
                          $colnames_output[$idx + @indices] .
                          ')' x scalar(@funcs);
                    }
                }

                push @indices, @indices_here;
            };



            # I want to find the requested column in the legend. First I look
            # for an exact string match, and if that doesn't work, I try to
            # match as a regex.

            @indices_here = grep {$col eq $cols_all[$_]} 0..$#cols_all;
            if ( @indices_here > 1 )
            {
                die "Found more than one column that string-matched '$col' exactly";
            }
            if( @indices_here == 1 )
            {
                $accept->();
                next;
            }

            # No exact match found. Try a regex
            @indices_here = grep {$cols_all[$_] =~ qr/$col/} 0..$#cols_all;
            if( @indices_here >= 1 )
            {
                $accept->();
                next;
            }

            die "Couldn't find requested column '$col' in the legend line '$_'";
        }

        if ( $options{dumpindices} )
        {
            print "@indices\n";
            exit;
        }

        # print out the new legend
        print "# @colnames_output\n";

        next;
    }

    # we got a data line
    next if $options{dumpindices};

    # select the columns we want
    chomp;
    my @f = split;
    @f = @f[@indices];


    for my $transform (@transforms)
    {
        # The indices here index the OUTPUT columns list
        my ($idx, @funcs) = @$transform;

        foreach my $func(@funcs)
        {
            $f[$idx] = $func->($f[$idx]);
        }
    }

    print "@f\n";
}






sub parse_transform_funcs
{
    sub parse_transform_func
    {
        my $f = shift;

        if( $f eq 'us2s' )
        {
            return sub { return $_[0] * 1e-6; };
        }
        elsif( $f eq 'deg2rad' )
        {
            return sub { return $_[0] * 3.141592653589793/180.0; };
        }
        elsif( $f eq 'rad2deg' )
        {
            return sub { return $_[0] * 180.0/3.141592653589793; };
        }
        elsif( $f eq 'rel' )
        {
            # relative to the starting value. The 'state' variable should be a
            # different instance for each sub instance
            return sub
            {
                state $x0;
                $x0 //= $_[0];
                return $_[0] - $x0;
            };
        }
        elsif( $f eq 'diff' )
        {
            # relative to the previous value. The 'state' variable should be a
            # different instance for each sub instance
            return sub
            {
                state $xprev;
                my $ret = 0;
                if(defined $xprev)
                {
                    $ret = $_[0] - $xprev;
                }
                $xprev = $_[0];
                return $ret;
            };
        }
        else
        {
            die "Unknown transform function '$f'";
        }
    }


    my @funcs = @_;
    return map { parse_transform_func($_) } @funcs;
}

__END__

=head1 NAME

asciilog-filter.pl - filters ascii logs to select particular fields

=head1 SYNOPSIS

    # Read log data, filter out the timestamps, and post-process some of them
    $ raw-log-read-ins /tmp/stereo_lump_log |
      asciilog_filter.pl '.*time' 'us2s(time)' 'rel(time)' 'rel(us2s(.*time))'

    # frame_time time us2s(time) rel(time) rel(us2s(frame_time)) rel(us2s(time))
    1434662133270338 1434662131279978 1434662131.27998 0 0 0
    1434662133270338 1434662131289978 1434662131.28998 10000 0 0.00999999046325684
    1434662133270338 1434662131299978 1434662131.29998 20000 0 0.0199999809265137
    1434662133270338 1434662131309978 1434662131.30998 30000 0 0.0299999713897705
    ...

    # Read log data, filter out the lat/lon, and make a plot
    $ raw-log-read-ins /tmp/stereo_lump_log |
      asciilog_filter.pl lat lon |
      feedgnuplot --domain --lines

    [ plot pops up]


=head1 DESCRIPTION

This tool reads in an ASCII data stream, and allows easy filtering to select
particular data from this stream. Many common post-processing operations are
available.

This is a UNIX-style tool, so the input/output of this tool is strictly
STDIN/STDOUT.

This tool is convenient both to filter stored data, or to filter live data that
can then be plotted to produce realtime telemetry.

This tool takes a list of fields on the commandline. These are the only fields
that are selected for output. The requested field names are compared with the
fields listed in the legend of the data. If an exact match is found, we select
that column. Otherwise we run a regex search, and take all matching columns.

The user often wants to apply unit conversions to data, or to look at the data
relative to the initial point, or to differentiate the input. These filters can
be easily applied by this tool.

=head2 Input/output data format

The input/output data is simply an ASCII table of values. Any lines beginning
with C<##> are treated as comments, and are passed through. The first line that
begins with C<#> but not C<##> is a I<legend> line. After the C<#>, follow
whitespace-separated ASCII field names. Each subsequent line is
whitespace-separated values matching this legend. For instance, this is a valid
data file:

    ## log version: 3 ins_type: RAW_LOG_INS_440 camera_type: Unknown camera_type id: 5
    ## camera 0: serial 0,1 cols/rows: 3904 3904 channels: 1 depth: 8
    ## camera 1: serial 2,3 cols/rows: 3904 3904 channels: 1 depth: 8
    ## camera 2: serial 4,0 cols/rows: 3904 3904 channels: 1 depth: 8
    ## camera 3: serial 0,0 cols/rows: 0 0 channels: 0 depth: 0
    # x_rate y_rate z_rate
    -0.016107 0.004362 0.005369
    -0.017449 0.006711 0.006711
    -0.018456 0.014093 0.006711
    -0.017449 0.018791 0.006376

This is the format for both the input and the output. This tool makes sure to
update the legend to reflect which columns have been selected.

=head2 Filters

We can post-process our data with filters. To apply filter =f= and then filter
=g= to column =x=, pass in =g(f(x))=. The filters currently available are

=over

=item C<us2s>

convert microseconds to seconds

=item C<deg2rad>

convert degrees to radians

=item C<rad2deg>

convert radians to degrees

=item C<rel>

report data relative to first value

=item C<diff>

report data relative to previous value

=back

=head1 ARGUMENTS

=head2 --dumpindices

This option exists only for debugging. If given, prints out the indices of all
the selected columns, and exits.

=head1 REPOSITORY

https://github.jpl.nasa.gov/maritime-robotics/asciilog/

=head1 AUTHOR

Dima Kogan C<< <Dmitriy.Kogan@jpl.nasa.gov> >>

=head1 LICENSE AND COPYRIGHT

Proprietary. Copyright 2016 California Institute of Technology
