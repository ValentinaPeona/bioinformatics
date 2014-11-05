#!/usr/bin/perl -w

#
# Uses htslib v1.0 to map two haploid samples fastq files to one of their
# assemblies
#

use strict;
use warnings;

use Getopt::Long;
use File::Spec;

# Allows use of perl modules in ./
use Cwd 'abs_path';
use File::Basename;
use lib dirname( abs_path $0 );
use lib dirname( abs_path $0 ) . "/../assembly_scripts";

use quake_wrapper;
use gff_to_vcf;
use assembly_common;
use mapping;

use threads;

#
# Globals
#

# htslib parameters
my $max_depth = 1000;

#
# Help and usage
#
my $usage_message = <<USAGE;
Usage: ./map_snp_call.pl -r <reference.fasta> -a <reference_annotation.gff> -r <reads_file> -o <output_prefix>

Maps input reads to reference, and calls snps

   Options
   -a, --assembly      Fasta file of reference to map to.
   -g, --annotation    Annotation of the reference to annotate variants with.
   -r, --reads         Tab delimited file of fastq or fastq.gz file locations.
                       One line per sample. First column sample name, second
                       column forward reads, third column reverse reads.
                       It is best to give absolute paths
   -o, --output        Prefix for output files

   -m, --mapper        Choose snap, bwa or smalt. Default snap
   -t, --threads       Number of threads to use. Default 1
   -p, --prior         Prior for number of snps expected. Default 1e-3

   --dirty             Don't remove temporary files

   -h, --help          Shows more detailed help.

Requires: smalt, samtools, bcftools
USAGE

#****************************************************************************************#
#* Subs                                                                                 *#
#****************************************************************************************#

# Converts sam to bam, sorts and indexes bam, deletes sam
# Returns name of bam
sub sort_sam($)
{
   my ($sam_file) = @_;

   # Set up file names
   my ($volume ,$directories, $file) = File::Spec->splitpath($sam_file);
   $file =~ m/^(.+)\.sam$/;
   my $file_prefix = $1;

   my $bam_file = $file_prefix . ".bam";

   # Do sorting and conversion (requires directory for temporary files
   my $tmp_prefix = "tmp" . assembly_common::random_string() . $file_prefix;
   my $sort_command = "samtools sort -O bam -o $bam_file -T $tmp_prefix $sam_file";

   if (!-d "tmp")
   {
      mkdir "tmp" || die("Could not make directory tmp: $!\n");
   }

   print STDERR "$sort_command\n";
   system($sort_command);

   # Always remove sam file immediately as it can be derived from bam, and it
   # is huge
   unlink $sam_file;

   # Index
   system("samtools index $bam_file");

   # Add tmp files
   assembly_common::add_tmp_file($bam_file);
   assembly_common::add_tmp_file("$bam_file.bai");

   return($bam_file);
}

# Takes a list of bams and their sample ids and merges them into a single bam
sub merge_bams($$$)
{
   my ($samples, $bam_files, $output_bam) = @_;

   # Write a header of read groups and sample names to use in the merge
   my $rg_name = "rg.txt";
   open(RG, ">$rg_name") || die("Could not open $rg_name for writing: $!\n");
   assembly_common::add_tmp_file($rg_name);

   my $i = 0;
   foreach my $sample (@$samples)
   {
      $$bam_files[$i] =~ m/^(.+)\.bam/;
      my $id = $1;

      print RG join("\t", '@RG', "ID:$id", "PL:ILLUMINA", "SM:$sample") . "\n";
      $i++;
   }

   close RG;

   # Do merge
   my $merge_command = "samtools merge -rh $rg_name $output_bam " . join(" ", @$bam_files);
   system ($merge_command);

   system ("samtools index $output_bam");

   # Add tmp files
   assembly_common::add_tmp_file($output_bam);
   assembly_common::add_tmp_file("$output_bam.bai");
}

#****************************************************************************************#
#* Main                                                                                 *#
#****************************************************************************************#

#* gets input parameters
my ($reference_file, $annotation_file, $read_file, $output_prefix, $threads, $prior, $mapper, $dirty, $help);
GetOptions ("assembly|a=s"  => \$reference_file,
            "annotation|g=s" => \$annotation_file,
            "reads|r=s"  => \$read_file,
            "output|o=s" => \$output_prefix,
            "threads|t=i" => \$threads,
            "prior|p=s"  => \$prior,
            "mapper|m=s" => \$mapper,
            "dirty" => \$dirty,
            "help|h"     => \$help
		   ) or die($usage_message);

# Parse input
if (defined($help))
{
   print $usage_message;
}
elsif (!defined($reference_file) || !defined($annotation_file) || !defined($read_file) || !defined($output_prefix))
{
   print STDERR $usage_message;
}
else
{
   # Set mapper
   my ($smalt, $bwa, $snap);
   if (defined($mapper))
   {
      if ($mapper eq "bwa")
      {
         $bwa = 1;
      }
      elsif ($mapper eq "smalt")
      {
         $smalt = 1;
      }
      else
      {
         $snap = 1;
      }
   }
   else
   {
      $snap = 1;
   }

   # Set default threads
   if (!defined($threads))
   {
      $threads = 1;
   }

   # Get array of samples and hash of read locations
   my ($samples, $reads) = quake_wrapper::parse_read_file($read_file, 1);

   # Index reference. Need to rename contigs as in annotation for annotation
   # transfer to vcf later
   my $new_ref = "reference.renamed.fa";
   assembly_common::standardise_contig_names($reference_file, $new_ref);
   assembly_common::add_tmp_file($new_ref);
   assembly_common::add_tmp_file("$new_ref.fai");

   $new_ref =~ m/^(.+)\.(fasta|fa)$/;
   my $ref_name = $1;

   $reference_file = $new_ref;

   # Map read pairs to reference with smalt (output sam files). Use threads
   # where possible
   my @bam_files;
   print STDERR "Now mapping...\n\n";

     # Create references and remove reference tmp files
   if ($smalt)
   {
      mapping::smalt_index($reference_file);

      assembly_common::add_tmp_file("$reference_file.sma");
      assembly_common::add_tmp_file("$reference_file.smi");
   }
   elsif ($bwa)
   {
      mapping::bwa_index($reference_file);

      assembly_common::add_tmp_file("$reference_file.amb");
      assembly_common::add_tmp_file("$reference_file.ann");
      assembly_common::add_tmp_file("$reference_file.bwt");
      assembly_common::add_tmp_file("$reference_file.pac");
      assembly_common::add_tmp_file("$reference_file.sa");
   }
   elsif ($snap)
   {
      mapping::snap_index($reference_file);

      assembly_common::add_tmp_file("snap_index");
   }

   for (my $i=0; $i<scalar(@$samples); $i+=$threads)
   {
      my @map_threads;
      for (my $thread = 1; $thread <= $threads; $thread++)
      {
         my $sample = $$samples[$i+$thread-1];
         my $forward_reads = $$reads{$sample}{"forward"};
         my $reverse_reads = $$reads{$sample}{"backward"};

         if ($smalt)
         {
            push(@map_threads, threads->create(\&mapping::run_smalt, $reference_file, $sample, $forward_reads, $reverse_reads));
         }
         elsif ($bwa)
         {
            push(@map_threads, threads->create(\&mapping::bwa_mem, $reference_file, $sample, $forward_reads, $reverse_reads));
         }
         elsif ($snap)
         {
            push(@map_threads, threads->create(\&mapping::run_snap, $reference_file, $sample, $forward_reads, $reverse_reads));
         }

         assembly_common::add_tmp_file("$sample.mapping.log");
      }

      # Wait for threads to rejoin before starting more
      foreach my $map_thread (@map_threads)
      {
         push (@bam_files, $map_thread->join());
      }

   }

   # Merge bams
   # Sample array is in the same order as bam file name array
   print STDERR "bam merge...\n";
   my $merged_bam = "$output_prefix.merged.bam";
   merge_bams($samples, \@bam_files, $merged_bam);

   # Call variants, running mpileup and then calling through a pipe
   print STDERR "variant calling...\n";
   my $calling_command;
   my $output_vcf = "$output_prefix.vcf.gz";

   # Write a sample file, defining all as haploid
   my $sample_file = "samples.txt";
   open SAMPLES, ">$sample_file" || die("Could not write to $sample_file: $!\n");
   foreach my $sample (@$samples)
   {
      print SAMPLES "$sample 1\n";
   }

   close SAMPLES;
   assembly_common::add_tmp_file($sample_file);

   # Use prior if given
   if (defined($prior))
   {
      $calling_command = "samtools mpileup -d $max_depth -t DP,SP -ug -f $reference_file $merged_bam | bcftools call -vm -P $prior -S $sample_file -O z -o $output_vcf";
   }
   else
   {
      $calling_command = "samtools mpileup -d $max_depth -t DP,SP -ug -f $reference_file $merged_bam | bcftools call -vm -S $sample_file -O z -o $output_vcf";
   }

   print STDERR "$calling_command\n";
   system($calling_command);

   # Annotate variants
   vcf_to_gff::transfer_annotation($annotation_file, $output_vcf);

   # Produced diff only vcf
   my $min_ac = 1;
   my $max_ac = scalar(@$samples) - 1;
   my $diff_vcf_name = "$output_prefix.diff.vcf.gz";
   system("bcftools view -c $min_ac -C $max_ac -o $diff_vcf_name -O z $output_vcf");
   system("bcftools index -f $diff_vcf_name");

   # TODO: bcftools stats, plot-vcfstats, bcftools filter
   #

   # Remove temporary files
   unless(defined($dirty))
   {
      assembly_common::clean_up();
   }
}

exit(0);

