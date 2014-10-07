#!/usr/bin/perl -w
#
use strict;
use warnings;

use Getopt::Long;

use Bio::SeqIO;
use Bio::Tools::GFF;

#
# Globals
#
my $query_fasta = "hsdS_query.fa";

my $N_term_ref = "Ntermini.fasta";
my $C_term_ref = "Ctermini.fasta";

my $N_blast_out = "Ntermini.blast.out";
my $C_blast_out = "Ctermini.blast.out";
my $blast_err = "blast.err";

my %allele_map = ("Aa" => "A",
                  "Ab" => "B",
                  "Ac" => "E",
                  "Ba" => "D",
                  "Bb" => "C",
                  "Bc" => "F");

my $help_message = <<HELP;
Usage: ./ivr_typer.pl [--map|--assembly] <options>

Given S. pneumo read (via mapping mode) or annotated assembly (via assembly mode),
returns information on the likely allele type for the ivr/hsd R-M system locus

   Options
   --map                 Infer by mapping reads to reference alleles
   --assembly            Infer by annotation of gene, then a blast with reference
                         genes

   --ref_dir             Directory containing sequences of reference alleles
                         (default ./)

   <map mode>
   -f, --forward_reads   Location of forward reads (fastq(.gz))
   -r, --reverse_reads   Location of reverse reads (fastq(.gz))

   <assembly mode>
   -a, --annotation      Annotation of the -a assembly in gff v3.


   -h, --help            Displays this message

For cortex, requires: cortex_var, bcftools, quake and jellyfish.
For sga, requires: sga
See help for more details
HELP

sub make_query_fasta($$)
{
   my ($genes, $f_out) = @_;

   my $sequence_out = Bio::SeqIO->new( -file   => ">$f_out",
                                       -format => "fasta") || die ($!);

   my $i = 1;
   foreach my $feature (@$genes)
   {
      my $new_gene = Bio::Seq->new( -seq => $feature->seq(),
                                    -display_id => "hsdS_$i");
      $i++;

      $sequence_out->write_seq($new_gene);
   }

   $sequence_out->close();
}

sub extract_hsds($)
{
   my ($annotation_file) = @_;

   my $gff_in = Bio::Tools::GFF->new(-file => $annotation_file,
                                     -gff_version => 3,
                                     -ignore_sequence => 0,
                                     -features_attached_to_seqs => 1) || die ("Could not open $annotation_file as gff v3: $!");

   # Hash of arrays, whose reference will be returned
   my %hsd_genes;
   my (@gene_order, @gene_strands);

   # Look through serially, find any hsd relevant genes
   while (my $feature = $gff_in->next_feature())
   {
      # Looking at products is more reliable than gene tags
      if ($feature->has_tag("product"))
      {
         my $strand = $feature->strand();
         push(@gene_strands, $strand);

         my $product = $feature->get_tag_values("product");

         # This annotation is part of a type I R-M system
         if ($product =~ /type I restriction/)
         {
            # Specificity subunit
            if ($product =~ /hsds/i || $product =~ /S protein/ || $product =~ /S subunit/)
            {
               push(@{ $hsd_genes{hsdS} }, $feature);
               push(@gene_order, "hsdS");
            }
            # Restriction subunit
            elsif ($product =~ /hsdr/i || $product =~ /R protein/ || $product =~ /R subunit/)
            {
               push(@{ $hsd_genes{hsdR} }, $feature);
               push(@gene_order, "hsdR");
            }
            # Methylation subunit
            elsif ($product =~ /hsdm/i || $product =~ /M protein/ || $product =~ /M subunit/)
            {
               push(@{ $hsd_genes{hsdM} }, $feature);
               push(@gene_order, "hsdM");

            }
         }
         # Possible creX/xerC gene, not too important to be specific here
         elsif($product =~ /recombinase/i)
         {
            push(@gene_order, "recombinase");
         }
         else
         {
            push(@gene_order, "-");
         }
      }
   }

   $gff_in->close();

   # Now look through gene order, and try and find hsdS flanked by hsdM and
   # creX/xerC
   my (@confident_hsds_genes, @likely_hsds_genes, @possible_hsds_genes, @hsds_genes);
   for (my $i = 0; $i < scalar(@gene_order); $i++)
   {
      if ($gene_order[$i] eq "hsdS")
      {
         if ($gene_order[$i-(1*$gene_strands[$i])] eq "hsdM" && $gene_order[$i+(1*$gene_strands[$i])] eq "recombinase")
         {
            push(@confident_hsds_genes, ${$hsd_genes{hsdS}}[$i]);
         }
         elsif ($gene_order[$i-(1*$gene_strands[$i])] eq "hsdM" || $gene_order[$i+(1*$gene_strands[$i])] eq "recombinase")
         {
            push(@likely_hsds_genes, ${$hsd_genes{hsdS}}[$i]);
         }
         else
         {
            push(@possible_hsds_genes, ${$hsd_genes{hsdS}}[$i]);
         }
       }
   }

   # Pick most confident existing set
   if (scalar(@confident_hsds_genes) > 0)
   {
      @hsds_genes = @confident_hsds_genes;
   }
   elsif (scalar(@likely_hsds_genes) > 0)
   {
      @hsds_genes = @likely_hsds_genes;
   }
   else
   {
      @hsds_genes = @possible_hsds_genes;
   }

   return(\@hsds_genes);
}

sub tblastx($$$)
{
   my ($subject, $query, $output_file) = @_;

   my $blast_command = "tblastx -subject $subject -query $query -outfmt \"6 qseqid sallseqid evalue score\" > $output_file 2> $blast_err";
   system($blast_command);

   # Parse output to extract best hit
   open(BLAST, "$output_file") || die("Could not open $output_file: $!\n");

   my $high_score = 0;
   my $top_hit;

   while (my $blast_line = <BLAST>)
   {
      chomp($blast_line);

      my ($query_id, $subject_id, $e_value, $score) = split("\t", $blast_line);
      if ($score > $high_score)
      {
         $top_hit = $subject_id;
      }
   }

   return($top_hit);
}

sub print_allele($$)
{
   my ($N_term, $C_term, $naming) = @_;

   print STDERR "Most likely (highest scoring) allele:\n";

   print join("\t", "$N_term$C_term", $allele_map{"$N_term$C_term"}) . "\n";
}


#
# Main
#
my ($map, $assembly, $ref_dir, $forward_reads, $reverse_reads, $annotation_file, $help);
GetOptions ("map"       => \$map,
            "assembly"    => \$assembly,
            "ref_dir=s" => \$ref_dir,
            "forward_reads|f=s" => \$forward_reads,
            "reverse_reads|r=s" => \$reverse_reads,
            "annotation|a=s" => \$annotation_file,
            "help|h"     => \$help
		   ) or die($help_message);

if (!defined($ref_dir))
{
   $ref_dir = ".";
}

if (defined($help))
{
   print $help_message;
}
elsif (defined($map))
{

}
elsif (defined($assembly))
{
   if (!defined($annotation_file) || !-e $annotation_file)
   {
      die("Must set $annotation_file for assembly mode\n");
   }

   print STDERR "Using assembly\n\n";

   # This returns gff features, with attached sequence
   my $hsds_genes = extract_hsds($annotation_file);

   # Process these objects into a multifasta to use as a blast query
   make_query_fasta($hsds_genes, $query_fasta);

   # Run a protein blast for C and N termini
   my $N_term = tblastx("$ref_dir/$N_term_ref", $query_fasta, $N_blast_out);
   if ($N_term =~ /^segment(.)$/)
   {
      $N_term = $1;
   }

   my $C_term = tblastx("$ref_dir/$C_term_ref", $query_fasta, $C_blast_out);
   if ($C_term =~ /^segment(.)$/)
   {
      $C_term = $1;
   }

   print_allele($N_term, $C_term);

}
else
{
   print STDERR "Mode must be set as one of map or assembly\n";
   print STDERR $help_message;
}

exit(0);

