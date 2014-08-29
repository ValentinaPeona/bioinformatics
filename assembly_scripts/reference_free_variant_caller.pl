#!/usr/bin/perl -w

#
# reference_free_variant_caller.pl
# arguments:   assembly.fa
#              annotation.gff
#              forward_reads.fastq
#              reverse_reads.fastq
#
# bsub this script with:
# bsub -o variation.%J.o -e variation.%J.e -R "select[mem>1000] rusage[mem=1000]" -M1000 -n6 -R "span[hosts=1]" ./reference_free_variant_caller.pl <arguments>

#
# Takes an assembly and two sets of paired reads and gets variation between
# samples using denovo assembly only. Output is a vcf where variants are called
# differently between the pair of samples, placed on the assembly provided, and
# annotated if they fall within a gene.
# Expected coverage for true variants is also output
#
# Requires cortex_var (>1.0.5.21), stampy, bcftools (>v1.0), quake (>v0.3) and
# jellyfish (>v2.0)
# Cortex binaries compiled:   cortex_var_31_c1
#                             cortex_var_63_c2
#
# To create an assembly for use with the script, try running (with parameters
# and jobids changed where appropriate):
# bsub -o spades.%J.o -e spades.%J.e -n4 -R "span[hosts=1]" -R "select[mem>6000] rusage[mem=6000]" -M6000 /nfs/users/nfs_j/jl11/software/bin/spades.py -o ./ -1 ../11822_8_30_1.fastq.gz -2 ../11822_8_30_2.fastq.gz --careful -t 4 -m 6 -k 21,25,29,33,37,41,45,49,53,57,61,65,69,73,77,81,85
# bsub -o SPAdes/filter.log -q small -w "done(1080103)" ~/bioinformatics/bacteria_scripts/filter_contigs.pl -i SPAdes/scaffolds.fasta -o SPAdes/scaffolds.filtered.fasta
# bsub -o improved_assemblies/SPAdes/improve_assembly.%J.o -e improved_assemblies/SPAdes/improve_assembly.%J.e -w "done(1081014)" -R "select[mem>3000] rusage[mem=3000]" -M3000 improve_assembly -a SPAdes/scaffolds.filtered.fasta -f 11822_8_30_1.fastq -r 11822_8_30_2.fastq -o improved_assemblies/SPAdes/
# and to annotate this
# bsub -w "done(1083756)" -o annotate.pipeline.%J.o -e annotate.pipeline.%J.e -M3000 -R "select[mem>3000] rusage[mem=3000]" -n4 -R "span[hosts=1]" annotate_bacteria -a scaffolds.scaffolded.gapfilled.length_filtered.sorted.fa --sample_name 2070227 --genus Streptococcus --cpus 4
#
# Note this is only use to place the called variants, and is not used during
# assembly of the pair
#

use strict;
use warnings;

use threads;
use Getopt::Long;

use Cwd 'abs_path';
use File::Basename;
use lib dirname( abs_path $0 );

use vcf_to_gff;

# Global locations of software needed
my $old_vcftools_location =  "/nfs/users/nfs_j/jl11/installations/vcftools_0.1.12a";
my $quake_location = "/nfs/users/nfs_j/jl11/software/bin/quake/quake.py";
my $cortex_wrapper = "/nfs/users/nfs_j/jl11/installations/CORTEX_release_v1.0.5.21/scripts/calling/run_calls.pl";
my $cortex_binaries = "/nfs/users/nfs_j/jl11/installations/CORTEX_release_v1.0.5.21/bin";
my $stampy_location = "/nfs/users/nfs_j/jl11/installations/stampy-1.0.23/stampy.py";

my @required_binaries = ("cortex_var_31_c1", "cortex_var_63_c2");

# Other global parameters

# Quake
my $quake_threads = 4;
my $quake_kmer_size = 14;

# Run calls.pl
my $first_kmer = 31;
my $last_kmer = 61;
my $kmer_step = $last_kmer - $first_kmer;
my $auto_cleaning = "yes";
my $bc = "yes";
my $pd = "no";
my $out_dir = "ctx_out";
my $ploidy = "1";
my $ref_bin_dir = "ref_binaries";
my $mem_height = 18;
my $mem_width = 100;
my $do_union = "yes";
my $ref_usage = "CoordinatesOnly";
my $workflow = "joint";
my $ctx_logfile = "cortex.bc.log";
my $ref_se = "REF_se";

my $filter_lines = <<'FILTERS';
##FILTER=<ID=PF_FAIL_ERROR,Description="Failed population filter">
##FILTER=<ID=PF_FAIL_REPEAT,Description="Identified as a repeat by population filter">
FILTERS

#
# Help and usage
#
my $usage_message = <<USAGE;
Usage: ./reference_free_variant_caller.pl -a <assembly.fasta> -g <annotation.gff> -r <reads_file>

Uses cortex_var to call variants between two samples without providing a reference
sequence

   Options
   -a, --assembly		Contigs of a de-novo assembly of one of the samples in
   	            	multi-fasta format. See help for more info.
   -g, --annotation	Annotation of the -a assembly in gff v3.
   -r, --reads	      Tab delimited file of fastq or fastq.gz file locations.
   	               One line per sample. First column sample name, second
                     column forward reads, third column reverse reads.
                     It is best to give absolute paths
   -o, --output 	   Prefix for output vcfs
   -h, --help	   	Shows more detailed help.

Requires: cortex_var, bcftools, quake and jellyfish. See help for more details
USAGE

my $help_message = <<HELP;

 reference_free_variant_caller.pl
 arguments:   assembly.fa
              annotation.gff
              forward_reads.fastq
              reverse_reads.fastq

 bsub this script with:
 bsub -o variation.%J.o -e variation.%J.e -R "select[mem>1000] rusage[mem=1000]" -M1000 -n6 -R "span[hosts=1]" ./reference_free_variant_caller.pl <arguments>

 Takes an assembly and two sets of paired reads and gets variation between
 samples using denovo assembly only. Output is a vcf where variants are called
 differently between the pair of samples, placed on the assembly provided, and
 annotated if they fall within a gene.
 Expected coverage for true variants is also output

 Requires cortex_var (>1.0.5.21), stampy, bcftools (>v1.0), quake (>v0.3) and
 jellyfish (>v2.0)
 Cortex binaries compiled:   cortex_var_31_c1
                             cortex_var_63_c2

 To create an assembly for use with the script, try running (with parameters
 and jobids changed where appropriate):
 bsub -o spades.%J.o -e spades.%J.e -n4 -R "span[hosts=1]" -R "select[mem>6000] rusage[mem=6000]" -M6000 /nfs/users/nfs_j/jl11/software/bin/spades.py -o ./ -1 ../11822_8_30_1.fastq.gz -2 ../11822_8_30_2.fastq.gz --careful -t 4 -m 6 -k 21,25,29,33,37,41,45,49,53,57,61,65,69,73,77,81,85
 bsub -o SPAdes/filter.log -q small -w "done(1080103)" ~/bioinformatics/bacteria_scripts/filter_contigs.pl -i SPAdes/scaffolds.fasta -o SPAdes/scaffolds.filtered.fasta
 bsub -o improved_assemblies/SPAdes/improve_assembly.%J.o -e improved_assemblies/SPAdes/improve_assembly.%J.e -w "done(1081014)" -R "select[mem>3000] rusage[mem=3000]" -M3000 improve_assembly -a SPAdes/scaffolds.filtered.fasta -f 11822_8_30_1.fastq -r 11822_8_30_2.fastq -o improved_assemblies/SPAdes/
 and to annotate this
 bsub -w "done(1083756)" -o annotate.pipeline.%J.o -e annotate.pipeline.%J.e -M3000 -R "select[mem>3000] rusage[mem=3000]" -n4 -R "span[hosts=1]" annotate_bacteria -a scaffolds.scaffolded.gapfilled.length_filtered.sorted.fa --sample_name 2070227 --genus Streptococcus --cpus 4

 Note this is only use to place the called variants, and is not used during
 assembly of the pair

HELP

#****************************************************************************************#
#* Functions                                                                            *#
#****************************************************************************************#
sub check_binaries()
{
   my $missing = 0;

   foreach my $binary (@required_binaries)
   {
      if (!-e "$cortex_binaries/$binary")
      {
         print STDERR "Cortex binary $binary does not exist in $cortex_binaries. It must be built before this pipeline can be run";
         $missing = 1;
      }
   }

   return($missing);
}

sub parse_read_file($)
{
   # Parses the read file names and sample names from the input read file.
   # Returns reference to an array of sample names, and a hash of read
   # locations.
   my $read_file = @_;

   open(READS, $read_file) || die("Could not open $read_file: $!\n");
   my %read_locations;
   my @sample_names;

   while (my $read_pair = <READS>)
   {
      chomp($read_pair);
      my ($sample_name, $forward_read, $backward_read) = split("\t", $read_pair);
      push(@sample_names, $sample_name);

      # Decompress reads if needed
      if ($forward_read =~ /\.gz$/)
      {
         $forward_read = decompress_fastq($forward_read);
      }
      if ($backward_read =~ /\.gz$/)
      {
         $backward_read = decompress_fastq($backward_read);
      }

      # Store in hash of hashes
      $read_locations{$sample_name}{"forward"} = $forward_read;
      $read_locations{$sample_name}{"backward"} = $backward_read;
   }

   close READS;
   return(\@sample_names, \%read_locations);
}

sub decompress_fastq($)
{
   my $fastq = @_;
   my $decompressed_location;
   my $cwd = getcwd();

   if ($fastq =~ /\/(.+\.fastq)\.gz$/)
   {
      $decompressed_location = "$cwd/$1";
   }

   system("gzip -d -c $fastq > $decompressed_location");

   return($decompressed_location);
}

# Error corrects fastq files using quake
sub quake_error_correct($)
{
   my $reads = @_;
   my %corrected_reads;

   # Prepare a file with the locations of the fastq file pairs for input to
   # quake
   my $quake_input_file_name = "quake_reads.txt";
   open (QUAKE, ">$quake_input_file_name") || die("Could not open $quake_input_file_name for writing: $!");

   foreach my $sample (keys %$reads)
   {
      my $forward_read = $$reads{$sample}{"forward"};
      my $backward_read = $$reads{$sample}{"backward"};

      print QUAKE join(" ", $forward_read, $backward_read) . "\n";
   }

   close QUAKE;

   # Run quake
   mkdir "quake" || die("Could not create quake directory: $!\n");
   chdir "quake";

   my $quake_command = "$quake_location -f $quake_input_file_name -k $quake_kmer_size -p $quake_threads 2>&1 > quake.log";
   system($quake_command);

   # Set paths of corrected reads
   my $cwd = getcwd();
   foreach my $sample (keys %$reads)
   {
      foreach my $read_direction (keys %{$$reads{$sample}})
      {
         if ($$reads{$sample}{$read_direction} =~ /\/(.+)\.fastq$/)
         {
            $corrected_reads{$sample}{$read_direction} = "$cwd/$1.cor.fastq";
         }
      }
   }

   chdir "..";

   return(\%corrected_reads);
}

# Creates binaries and a stampy hash of a reference sequence
sub prepare_reference($)
{
   my $reference_file = @_;

   my @cortex_threads;

   # Put assembly.fa location into file for cortex input
   system("cat $reference_file > $ref_se");
   mkdir "$ref_bin_dir" || die("Could not make directory $ref_bin_dir: $!\n");
   chdir "$ref_bin_dir";

   # Dump a binary for each kmer being used
   my $i = 0;

   for (my $kmer = $first_kmer; $kmer<=$last_kmer; $kmer+= $kmer_step)
   {
      $cortex_threads[$i] = threads->create(\&build_binary, $kmer, 1, "../$ref_se");
      $i++;
   }

   # Make a stampy hash of the reference
   my $stampy_command = "$stampy_location -G REF $reference_file";
   system($stampy_command);

   $stampy_command = "$stampy_location -g REF -H REF";
   system($stampy_command);

   # Wait for cortex jobs to finish
   foreach my $thread (@cortex_threads)
   {
      $thread->join();
   }

   chdir ".."
}

# Builds binaries of a reference using cortex
sub build_binary($$$)
{
   my ($kmer, $colours, $ref_file) = @_;

   # Find required binary
   my $correct_binary;
   foreach my $binary (@required_binaries)
   {
      if ($binary =~ /^cortex_var_(\d+)_c(\d+)$/)
      {
         if ($1 >= $kmer && $2 >= $colours)
         {
            $correct_binary = $binary;
         }
      }
   }

   # At the moment, should only encounter this due to an error in the script so
   # don't worry too much about giving a helpful error message
   if (!defined($correct_binary))
   {
      die("No suitable binary for kmer $kmer and $colours colour(s) exists.\n");
   }

   my $cortex_command = "$cortex_binaries/$correct_binary --kmer_size $kmer --mem_height $mem_height --mem_width $mem_width --se_list $ref_file --dump_binary ref.k$kmer.ctx --sample_id REF";
   system("$cortex_command 2>&1 > ctx.ref.k$kmer.log");
}

# Gets the total sequence length of a multi-fasta file
sub reference_length($)
{
   my $reference_file = @_;

   my $length = `grep -v ">" $reference_file | wc -m`;

   return($length);
}

# Creates an index file for use by run_calls.pl
sub create_cortex_index($)
{
   # A reference to a hash of read locations
   # %$reads{sample}{direction}
   my $reads = @_;

   my $index_name = "INDEX";

   # INDEX file is one row per sample, columns: sample name, se reads, forward
   # pe reads, reverse pe reads. Empty fields marked by periods
   open(INDEX, ">$index_name") || die("Could not write to $index_name: $!\n");

   foreach my $sample (keys %$reads)
   {
      my $pe_1 = $sample . "_pe_1";
      my $pe_2 = $sample . "_pe_2";

      print INDEX join("\t", $sample, ".", $pe_1, $pe_2) . "\n";
      open(PE_F, ">$pe_1") || die("Could not open $pe_1 for writing: $!\n");
      open(PE_R, ">$pe_2") || die("Could not open $pe_2 for writing: $!\n");

      print PE_F $$reads{$sample}{"forward"};
      print PE_R $$reads{$sample}{"backward"};

      close PE_F;
      close PE_R;
   }

   close INDEX;
   return($index_name);
}

#****************************************************************************************#
#* Main                                                                                 *#
#****************************************************************************************#

#* gets input parameters
my ($assembly_file, $annotation_file, $read_file, $output_prefix, $help);
GetOptions ("assembly|a=s"  => \$assembly_file,
            "annotation|g=s" => \$annotation_file,
            "reads|r=s"  => \$read_file,
            "output|o=s"  => \$output_prefix,
            "help|h"     => \$help
		   ) or die($usage_message);

# Parse input
if (!defined($assembly_file) || !defined($annotation_file) || !defined($read_file) || !defined($output_prefix))
{
   print STDERR $usage_message;
}
elsif (!-e $assembly_file || !-e $annotation_file || !-e $read_file)
{
   print STDERR "One or more specified input files do not exist\n";
   print STDERR $usage_message;
}
elsif (defined($help))
{
   print $help_message;
}
elsif (check_binaries())
{
   print STDERR "See compile instructions in cortex documentation";
}
else
{
   my $cwd = getcwd();
   my ($samples, $reads) = parse_read_file($read_file);

   print STDERR "Error correcting reads and preparing assembly\n";

   # Thread to error correct reads
   # Note this returns location of corrected reads
   my $quake_thread = threads->create(\&quake_error_correct, $reads);

   # Thread to prepare reference with cortex and stampy
   my $reference_thread = threads->create(\&prepare_reference, $assembly_file);

   # Run cortex once threads have finished
   $reference_thread->join();
   my $index_name = create_cortex_index($quake_thread->join());

   my $approx_length = reference_length($assembly_file);

   my $cortex_command = "perl $cortex_wrapper --first_kmer $first_kmer --last_kmer $last_kmer --kmer_step $kmer_step --fastaq_index $index_name --auto_cleaning $auto_cleaning --bc $bc --pd $pd --outdir $out_dir --outvcf $output_prefix --ploidy $ploidy --refbindir $ref_bin_dir --list_ref_fasta $ref_se --stampy_hash REF --stampy_bin $stampy_location --genome_size $approx_length --mem_height $mem_height --mem_width $mem_width --squeeze_mem --vcftools_dir $old_vcftools_location --do_union $do_union --ref $ref_usage --workflow $workflow --logfile $ctx_logfile --apply_pop_classifier";

   print STDERR "Running cortex\n";
   system("$cortex_command 2>&1 > cortex.err");

   # Output expected coverage for each variant type

   # Fix vcf output
   # TODO: This isn't ideal as some of the name is hard coded when it can be inferred
   # from the run_calls.pl parameters
   my $output_vcf = "$cwd/$out_dir/vcfs/$output_prefix" . "_wk_flow_J_Ref_CO_FINALcombined_BC_calls_at_all_k.decomp.vcf";
   print STDERR "Cortex output vcf is: $output_vcf\n\n";
   print STDERR "Fixing and annotating vcf\n";

   # Reheader vcf with bcftools as pop filter FILTER fields not included (bug in cortex)
   system("$vcf_to_gff::bcftools_location view -h $output_vcf > vcf_header.tmp");
   system("head -n -1 vcf_header.tmp > vcf_header_reduced.tmp");
   system("tail -1 vcf_header.tmp > vcf_column_headings.tmp");

   open(FILTERS, ">filters.tmp") || die("Could not write to filters.tmp: $!\n");
   print FILTERS $filter_lines;
   close FILTERS;

   system("cat vcf_header_reduced.tmp filters.tmp vcf_column_headings.tmp > new_header.tmp");
   system("$vcf_to_gff::bcftools_location reheader -h new_header.tmp $output_vcf -o $output_vcf");
   unlink "vcf_header.tmp", "vcf_header_reduced.tmp", "vcf_column_headings.tmp", "filter.tmp", "new_header.tmp";

   # Fix error in filter fields introduced by population filter fields, then
   # bgzip and index
   my $fixed_vcf = "$cwd/$output_prefix.decomposed_calls.vcf.gz";
   my $filtered_vcf = "$cwd/$output_prefix.filtered_calls.vcf.gz";

   system("sed -i -e 's/,PF/;PF/g' $output_vcf");
   system("bgzip -c $output_vcf > $fixed_vcf");
   system("$vcf_to_gff::bcftools_location index $fixed_vcf");

   # Annotate vcf, and extract passed variant sites only
   vcf_to_gff::transfer_annotation($annotation_file, $fixed_vcf);

   system("$vcf_to_gff::bcftools_location view -C 2 -c 2 -f PASS $fixed_vcf -o $filtered_vcf -O z");
   system("$vcf_to_gff::bcftools_location index $filtered_vcf");

   print STDERR "Final output:\n$filtered_vcf\n";
}

exit(0);

