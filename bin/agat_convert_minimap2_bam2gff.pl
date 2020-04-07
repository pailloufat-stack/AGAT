#!/usr/bin/env perl
use strict;
use warnings;
use Cwd;
use File::Basename;
use Getopt::Long;
use Pod::Usage;
use AGAT::Omniscient;


my $header = get_agat_header();
my $intronID = 1;
my $opt_in;
my $opt_bam;
my $opt_sam;
my $opt_output=undef;
my $opt_help = 0;

if ( !GetOptions( 'i|input=s' => \$opt_in,
                  'b|bam!' => \$opt_bam,
									's|sam!' => \$opt_sam,
                  'o|out|output=s' => \$opt_output,
                  'h|help!'         => \$opt_help ) )
{
    pod2usage( { -message => 'Failed to parse command line',
                 -verbose => 1,
                 -exitval => 1 } );
}

# Print Help and exit
if ($opt_help) {
    pod2usage( { -verbose => 99,
                 -exitval => 0,
                 -message => "$header\n" } );
}

if ( ! defined( $opt_in) ) {
    pod2usage( {
           -message => "$header\nMust specify at least 1 parameters: Input sam or bam file (-i)\n",
           -verbose => 0,
           -exitval => 1 } );
}

# ---- set output -----
my $out_stream;
if ($opt_output) {
	$out_stream=IO::File->new(">".$opt_output ) or croak( sprintf( "Can not open '%s' for writing %s", $opt_output, $! ));
}
else{
	$out_stream = \*STDOUT or die ( sprintf( "Can not open '%s' for writing %s", "STDOUT", $! ));
}

# ----- Parse input ------
my $is_sam=undef;
if($opt_sam){
	$is_sam=1;
}
elsif($opt_bam){
	$is_sam=undef;
}
#test by extension
else{
	my ($filename,$path,$ext) = fileparse($opt_in,qr/\.[^.]*/);
	if($ext eq ".sam"){
		$is_sam=1;
	}
	elsif($ext eq ".bam"){
		$is_sam=undef;
	}
	else{
		die "No sam or bam extension, we cannot guess the type of file.\n".
		"You can inform the tool by using --sam or --bam option\n";
	}
}

## FROM HERE $is_sam=1 => sam  $is_sam=undef => bam

if ($is_sam){
	open(FILE, '<:encoding(UTF-8)', $opt_in)
  						or die "Could not open file '$opt_in' $!";
}
else{
	my @tools = ("samtools");
	foreach my $exe (@tools) {
	    check_bin($exe) == 1 or die "Missing executable $exe in PATH";
	}
	open FILE,"samtools view $opt_in |";
}

## CHECK BAM file exits !


my $COUNTER=0;

while(<FILE>){
  next if(/^(\@)/);  ## skipping the header lines (if you used -h in the samools command)
  s/\n//;  s/\r//;  ## removing new line
  my @sam = split(/\t+/);  ## splitting SAM line into array

	my %entry = ( "qname" => $sam[0], "flag" => $sam[1], "rname" => $sam[2], "pos" => $sam[3], "mapq" => $sam[4],
		"cigar" => $sam[5], "rnext" => $sam[6], "pnext" => $sam[7], "tlen" => $sam[8], "seq" => $sam[9], "qual" => $sam[10] );

	my $AS="."; # Alignment score generated by aligner. Should we use s1 isntead?
	my @matching_as = grep { /^AS:/  } @sam;
	if(	@matching_as ) {
		  my @AS_list= split(/:/, @matching_as[0]);  ## splitting line into array
			$AS = $AS_list[2];
	}


	# Skip this entry if it has no sequence
	if ($entry{'seq'} eq '*') {
		next ;
	}

	# query is unmapped
	if ($entry{'flag'} & 0x0004) {
		next;
	}

	my $num_mismatches = 0;

	if ( join("\t",@sam) =~ /NM:i:(\d+)/) {
		$num_mismatches = $1;
  }

	# get the strand of the alignment
	my $strand = undef;
	if ($entry{"flag"} == 0) {
		$strand = "+" ;
	} elsif ($entry{"flag"} == 16) {
		$strand = "-" ;
	# Flag suggests other factors, will ignore this mapping
	} else {
		next;
	}

	$entry{"strand"} = $strand ;

	my $read_name = $entry{"qname"} ;
	my $scaff_name = $entry{"rname"};

	my ($genome_coords_aref, $query_coords_aref) = get_aligned_coords(%entry);

	my $align_len = 0;

	foreach my $coordset (@$genome_coords_aref) {
    $align_len += abs($coordset->[1] - $coordset->[0]) + 1;
  }
	# Check this...
	next if ($align_len eq 0);

	my $per_id = sprintf("%.1f", 100 - $num_mismatches/$align_len * 100);

	# discard all mappings below 80%
	if ($per_id < 90.0) {
		next;
	}

	my $align_counter_l1 = "match" . ++$COUNTER;
	my $align_counter_l2 = $align_counter_l1.".p1";

	my @genome_n_trans_coords;

  while (@$genome_coords_aref) {
    my $genome_coordset_aref = shift @$genome_coords_aref;
    my $trans_coordset_aref = shift @$query_coords_aref;

    my ($genome_lend, $genome_rend) = @$genome_coordset_aref;

    my ($trans_lend, $trans_rend) = sort {$a<=>$b} @$trans_coordset_aref;

    push (@genome_n_trans_coords, [ $genome_lend, $genome_rend, $trans_lend, $trans_rend ] );
  }

	my @merged_coords;
  push (@merged_coords, shift @genome_n_trans_coords);

  my $MERGE_DIST = 10;
  while (@genome_n_trans_coords) {
      my $coordset_ref = shift @genome_n_trans_coords;
      my $last_coordset_ref = $merged_coords[$#merged_coords];

      if ($coordset_ref->[0] - $last_coordset_ref->[1] <= $MERGE_DIST) {
          # merge it.
          $last_coordset_ref->[1] = $coordset_ref->[1];

          if ($strand eq "+") {
              $last_coordset_ref->[3] = $coordset_ref->[3];
          } else {
              $last_coordset_ref->[2] = $coordset_ref->[2];
          }
      }
      else {
          # not merging.
          push (@merged_coords, $coordset_ref);
      }
  }
	my ($genome_lend, $genome_rend, $trans_lend, $trans_rend) = @{$merged_coords[0]};
	my ($genome_lend2, $genome_rend2, $trans_lend2, $trans_rend2) = @{$merged_coords[$#merged_coords]};
	print $out_stream join("\t",
						 $scaff_name,
						 "est2genome",
						 "cDNA_match",
						 $genome_lend, $genome_rend2,
						 $AS,
						 $strand,
						 ".",
						 "ID=$align_counter_l1;aligned_identity=$per_id") . "\n"; # target_length and aligned_coverage attributes cannot be determined

	foreach my $coordset_ref (@merged_coords) {
            my ($genome_lend, $genome_rend, $trans_lend, $trans_rend) = @$coordset_ref;

						print $out_stream join("\t",
	                      $scaff_name,
	                      "est2genome",
	                      "cDNA_match_part",
	                      $genome_lend, $genome_rend,
	                      $AS,
	                      $strand,
	                      ".",
	                      "ID=$align_counter_l2;Parent=$align_counter_l1;Target=$read_name $trans_lend $trans_rend") . "\n";
	}
	#print "\n";
}

sub get_aligned_coords {

	my %entry = @_;

	my $genome_lend = $entry{"pos"};

	my $alignment = $entry{"cigar"};
	my $query_lend = 0;

	my @genome_coords;
	my @query_coords;

	$genome_lend--;

	while ($alignment =~ /(\d+)([A-Z])/g) {

		my $len = $1;
		my $code = $2;

		unless ($code =~ /^[MSDNIH]$/) {
			die  "Error, cannot parse cigar code [$code] ";
		}

		#print "parsed $len,$code\n";

		if ($code eq 'M') { # aligned bases match or mismatch

			my $genome_rend = $genome_lend + $len;
			my $query_rend = $query_lend + $len;

			push (@genome_coords, [$genome_lend+1, $genome_rend]);
			push (@query_coords, [$query_lend+1, $query_rend]);

			# reset coord pointers
			$genome_lend = $genome_rend;
			$query_lend = $query_rend;
		}
		elsif ($code eq 'D' || $code eq 'N') { # insertion in the genome or gap in query (intron, perhaps)
			$genome_lend += $len;

		}

		elsif ($code eq 'I'  # gap in genome or insertion in query
               ||
               $code eq 'S' || $code eq 'H')  # masked region of query
        {
            $query_lend += $len;

		}
	}

	 ## see if reverse strand alignment - if so, must revcomp the read matching coordinates.
    	if ($entry{"strand"} eq '-') {

        my $read_len = length($entry{"seq"});
        unless ($read_len) {
            die "Error, no read length obtained from entry";
        }

        my @revcomp_coords;
        foreach my $coordset (@query_coords) {
            my ($lend, $rend) = @$coordset;

            my $new_lend = $read_len - $lend + 1;
            my $new_rend = $read_len - $rend + 1;

            push (@revcomp_coords, [$new_lend, $new_rend]);
        }

        @query_coords = @revcomp_coords;

    }

	return(\@genome_coords, \@query_coords);
}

################################################################################
        ####################
         #     METHODS    #
          ################
           ##############
            ############
             ##########
              ########
               ######
                ####
                 ##

sub check_bin
{
    length(`which @_`) > 0 ? return 1 : return 0;
}


__END__

Tag	Type	Description
tp	A	Type of aln: P/primary, S/secondary and I,i/inversion
cm	i	Number of minimizers on the chain
s1	i	Chaining score
s2	i	Chaining score of the best secondary chain
NM	i	Total number of mismatches and gaps in the alignment
MD	Z	To generate the ref sequence in the alignment
AS	i	DP alignment score
ms	i	DP score of the max scoring segment in the alignment
nn	i	Number of ambiguous bases in the alignment
ts	A	Transcript strand (splice mode only)
cg	Z	CIGAR string (only in PAF)
cs	Z	Difference string
dv	f	Approximate per-base sequence divergence
de	f	Gap-compressed per-base sequence divergence
rl	i	Length of query regions harboring repetitive seeds

=head1 NAME

agat_convert_sp_minimap2_bam2gff.pl

=head1 DESCRIPTION

The script converts output from minimap2 (bam or sam) into gff file.
To get bam from minimap2 use the following command:
minimap2 -ax splice:hq genome.fa Asecodes_parviclava.nucest.fa | samtools sort -O BAM -o output.bam
To use bam with this script you will need samtools in your path.

=head1 SYNOPSIS

    agat_convert_sp_minimap2_bam2gff.pl -i infile.bam [ -o outfile ]
    agat_convert_sp_minimap2_bam2gff.pl -i infile.sam [ -o outfile ]
    agat_convert_sp_minimap2_bam2gff.pl --help

=head1 OPTIONS

if ( !GetOptions( 'i|input=s' => \$opt_in,

=over 8

=item B<-i> or B<--input>

Input file in sam (.sam extension) or bam (.bam extension) format.

=item B<-b> or B<--bam>

To force to use the input file as sam file.

=item B<-s> or B<--sam>

To force to use the input file as sam file.

=item B<-o>, B<--out> or B<--output>

Output GFF file.  If no output file is specified, the output will be
written to STDOUT.

=item B<-h> or B<--help>

Display this helpful text.

=back

=head1 FEEDBACK

=head2 Did you find a bug?

Do not hesitate to report bugs to help us keep track of the bugs and their
resolution. Please use the GitHub issue tracking system available at this
address:

            https://github.com/NBISweden/AGAT/issues

 Ensure that the bug was not already reported by searching under Issues.
 If you're unable to find an (open) issue addressing the problem, open a new one.
 Try as much as possible to include in the issue when relevant:
 - a clear description,
 - as much relevant information as possible,
 - the command used,
 - a data sample,
 - an explanation of the expected behaviour that is not occurring.

=head2 Do you want to contribute?

You are very welcome, visit this address for the Contributing guidelines:
https://github.com/NBISweden/AGAT/blob/master/CONTRIBUTING.md

=cut
# This is a rip-off from Brian Haas's Sam_to_gtf.pl converter bundled with PASA
# Needed this as a standalone version.
AUTHOR - Brian Haas, Marc Hoeppner, Jacques Dainat
