#!/usr/bin/perl -w
# $Id: Makefile.PL 2693 2008-01-02 09:54:19Z hospelt $
use 5.008004;
use ExtUtils::MakeMaker;
our $VERSION = '1.005';

WriteMakefile
    (NAME		=> 'WEC::Lirc',
     VERSION		=> "0.01",
     PREREQ_PM		=> {}, # e.g., Module::Name => 1.1
     PREREQ_PM		=> {
         WEC			=> 0.01,
         "Exporter::Tidy"	=> 0.05,
         "Test::More"		=> 0.11,	# For the tests only
     },
     AUTHOR	=> 'Ton Hospel <WEC-MySQL@ton.iguana.be>',
     $^O eq "MSWin32" ? (
         PM_FILTER	=> '$(PERL) -p -e1',
     ) : (),
     clean		=> {
         FILES => '$(DISTNAME).ppd ppm cover_db',
     },
    );

# START MY
# END MY
