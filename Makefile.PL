#!/usr/bin/env perl

use strict;
use warnings;
use ExtUtils::MakeMaker 7.12;    # for XSMULTI option

WriteMakefile(
    NAME          => 'Lorraine',
    VERSION_FROM  => 'lib/Lorraine.pm',
    PREREQ_PM     => { 'ExtUtils::MakeMaker' => '7.12' },
    ABSTRACT_FROM => 'lib/Lorraine.pm',
    AUTHOR        => 'Rawley Fowler',
    CCFLAGS       => '-Wall -std=c99',
    OPTIMIZE      => '-O3',
    LICENSE       => 'mit',
    XSMULTI       => 1,
);
