
# Copyright (C) 2011-2019 R. Diez - Licensed under the GNU AGPLv3

package ReportUtils;

use strict;
use warnings;

use XML::Parser;
use HTML::Entities;
use File::Spec;
use File::Glob;
use I18N::Langinfo;
use Encode;

use StringUtils;
use FileUtils;
use ConfigFile;
use MiscUtils;

# In order of priority in the HTML report.
use constant RT_GROUP      => 1;
use constant RT_SUBPROJECT => 2;
use constant RT_NORMAL     => 3;


sub collect_all_reports ( $ $ $ $ $ )
{
  my $dirname            = shift;
  my $reportExtension    = shift;
  my $optionalEntries    = shift;  # Reference to an array.
  my $allReportsArrayRef = shift;
  my $failedCount        = shift;

  my $globPattern = FileUtils::cat_path( $dirname, "*" . $reportExtension );

  my @matchedFiles = File::Glob::bsd_glob( $globPattern, &File::Glob::GLOB_ERR | &File::Glob::GLOB_NOSORT );

  if ( &File::Glob::GLOB_ERROR )
  {
    die "Error listing existing directories: $!\n";
  }

  $$failedCount = 0;

  foreach my $filename ( @matchedFiles )
  {
    if ( FALSE )
    {
      print "File found: $filename\n";
    }

    if ( not -f $filename )
    {
      die "File \"$filename\" is not a regular file.\n"
    }

    my %allEntries;

    load_report( $filename, $optionalEntries, \%allEntries );

    my $hideOptionStr = $allEntries{ "HideFromReportIfSuccessful" };
    my $hideOption;

    if ( $hideOptionStr eq "true" )
    {
      $hideOption = TRUE;
    }
    elsif ( $hideOptionStr eq "false" )
    {
      $hideOption = FALSE;
    }
    else
    {
      die "Error loading report \"$filename\": Setting 'HideFromReportIfSuccessful' has invalid value '$hideOptionStr'.\n";
    }

    my $exitCode = $allEntries{ "ExitCode" };

    if ( $exitCode == 0 && $hideOption )
    {
      next;
    }

    if ( $exitCode != 0 )
    {
      ++$$failedCount;
    }

    push @$allReportsArrayRef, \%allEntries;
  }
}


sub load_report ( $ $ $ )
{
  my $filename          = shift;
  my $optionalEntries   = shift;  # Reference to an array.
  my $allEntriesHashRef = shift;

  ConfigFile::read_config_file( $filename, $allEntriesHashRef );

  my @mandatoryEntries = qw( ReportFormatVersion
                             UserFriendlyName
                             ProgrammaticName
                             ExitCode
                             HideFromReportIfSuccessful
                             LogFile
                             StartTimeLocal
                             StartTimeUTC
                             FinishTimeLocal
                             FinishTimeUTC
                             ElapsedSeconds  );

  ConfigFile::check_config_file_contents( $allEntriesHashRef,
                                          \@mandatoryEntries,
                                          $optionalEntries,
                                          $filename );

  my $formatVersion = $allEntriesHashRef->{ "ReportFormatVersion" };

  if ( $formatVersion != 1 )
  {
    die "Error loading report \"$filename\": Report file format version '$formatVersion' not supported.\n";
  }
}


sub add_setting ( $ $ $ )
{
  my $report  = shift;
  my $setting = shift;
  my $value   = shift;

  if ( exists $report->{ $setting } )
  {
    die "Internal error: The report has already a setting called '$setting'.\n";
  }

  $report->{ $setting } = $value;
}


sub check_valid_html ( $ )
{
  my $str = shift;

  # At the moment, the only check is that the string is valid XML,
  # but we could probably test more.
  my $parser = XML::Parser->new();

  $parser->parse( $str );
}


sub replace_marker ( $ $ $ )
{
  my $strRef      = shift;  # Reference to a string, like this:  \$string
  my $markerName  = shift;
  my $markerValue = shift;

  # Markers look like this:  ${ NAME }

  $$strRef =~ s/\$\{\s*$markerName\s*\}/$markerValue/g;
}


sub get_report_type ( $ )
{
  my $report = shift;

  my $type = $report->{ "ReportType" };

  if ( not defined $type )
  {
    return RT_NORMAL;
  }
  else
  {
    return $type;
  }
}


sub sort_reports ( $ $ )
{
  my $allReports               = shift;
  my $userFriendlyNameAtTheTop = shift;  # If successful, it goes at the top. If failed, after any other failures.

  my $comparator = sub ($$)  #  "local *comparator" is allegedly better as "my $comparator",
  {                          #  especially for recursive nested routines, but you get a compilation warning.
    my $left  = shift;
    my $right = shift;

    my $leftExitCodeSuccess  =  0 == $left ->{ "ExitCode" };
    my $rightExitCodeSuccess =  0 == $right->{ "ExitCode" };


    # Failed tasks have priority.

    if ( $leftExitCodeSuccess )
    {
      if ( $rightExitCodeSuccess )
      {
        # Nothing to do here, drop below.
      }
      else
      {
        return +1;
      }
    }
    else
    {
      if ( $rightExitCodeSuccess )
      {
        return -1;
      }
      else
      {
        # Nothing to do here, drop below.
      }
    }


    # There can be one task that should always be at the top
    # or at the bottom, depending on the success/failed status.

    if ( $left->{ "UserFriendlyName" } eq $userFriendlyNameAtTheTop )
    {
      return $leftExitCodeSuccess ? -1 : +1;
    }

    if ( $right->{ "UserFriendlyName" } eq $userFriendlyNameAtTheTop )
    {
      return $rightExitCodeSuccess ? +1 : -1;
    }


    # Sort reports by their type.

    my $leftType  = get_report_type( $left  );
    my $rightType = get_report_type( $right );

    if ( $leftType != $rightType )
    {
      return $leftType - $rightType;
    }


    # We could sort all failed tasks by their timestamp, as it's roughly
    # the dependency order, that is, the order in which they were executed.
    # However, I'm not certain that sorting by name is not actually better,
    # as it allows the user to skip at once groups of uninteresting failures.

    return $left->{ "UserFriendlyName" }  cmp  $right->{ "UserFriendlyName" };
  };

  my @sortedReports = sort $comparator @$allReports;

  return @sortedReports;
}


sub get_default_encoding ()
{
  # The build log outputs are redirected to files, which are normally encoded in UTF-8,
  # but could be encoded in some other system default encoding.
  # If we don't specify any encoding when reading the files, the UTF-8 characters are garbled in the resulting HTML page.
  # Here we are attempting to find out the system's default text encoding.
  # Alternatively, we could use module Encode::Locale and then binmode( ':encoding(locale)' ),
  # but that module is not usually installed.
  my $defaultCodeset = I18N::Langinfo::langinfo( I18N::Langinfo::CODESET() );
  my $defaultEncoding = Encode::find_encoding( $defaultCodeset )->name;

  if ( FALSE )
  {
    print "Default encoding: $defaultEncoding\n";
  }

  return $defaultEncoding;
}


sub convert_text_file_to_html ( $ $ $ )
{
  my $srcFilename     = shift;
  my $destFilename    = shift;
  my $defaultEncoding = shift;

  open( my $srcFile, "<$srcFilename" )
    or die "Cannot open file \"$srcFilename\": $!\n";

  # Turning on the encoding here slows reads down considerably.
  binmode( $srcFile, ":encoding($defaultEncoding)" )  # Also avoids CRLF conversion.
    or die "Cannot access file in binary mode or cannot set the file encoding: $!\n";

  open( my $destFile, ">$destFilename" )
    or die "Cannot open for writing file \"$destFilename\": $!\n";

  binmode( $destFile )  # Avoids CRLF conversion.
    or die "Cannot access file in binary mode: $!\n";

  $destFile->autoflush( 0 );  # Make sure the file is being buffered, for performance reasons.

  # Alternative with HTML::FromText :
  #   my $logFilenameContents = FileUtils::read_whole_binary_file( $logFilename );
  #   my $t2h  = HTML::FromText->new( { lines => 1 } );
  #   my $logContentsAsHtml = $t2h->parse( $logFilenameContents );

  my $header = "<!DOCTYPE HTML>\n" .
               "<html>\n" .
               "<head>\n" .
               "<title>Log file</title>\n" .
               "<style type=\"text/css\">\n" .

               "td.linenumber {\n" .
               "  text-align:right;\n" .
               "  font-family: monospace;\n" .
               "  vertical-align: top;\n" .
               "  padding-right: 10px;\n" .
               "  border-style: solid;\n" .
               "  border-width: 1px;\n" .
               "  border-color: #B0B0B0;\n" .
               "}\n" .

               "td.logline {\n" .
               "  text-align:left;\n" .
               "  font-family: monospace;\n" .
               "  padding-left:  10px;\n" .
               "  padding-right: 10px;\n" .
               "  border-style: solid;\n" .
               "  border-width: 0px;\n" .
               "  word-break: break-all;\n" .  # CSS3, only supported by Microsoft Internet Explorer (tested with version 9) and
                                               # Chromium (tested with version 17), but not by Firefox 10.
                                               # Without it, very long lines will cause horizontal scroll-bars to appear at bottom of the page.
                                               # The alternative 'break-word' works well with Chromium, chopping at word boundaries except when the word is too long,
                                               # but unfortunately it does not well with IE 9 (scroll-bars appear again).
               "}\n" .

               "</style>\n" .
               "</head>\n" .
               "<body>\n" .
               "<table border=\"1\" CELLSPACING=\"0\">\n" .
               "<thead>\n" .
               "<tr>\n" .
               "<th>LN</th>\n" .
               "<th>Log Line Text</th>\n" .
               "</tr>\n" .
               "</thead>\n" .
               "<tbody>\n";

  (print $destFile $header) or
      die "Cannot write to file \"$destFilename\": $!\n";

  my $htmlBr = "<br/>";


  # This loop is rather slow. I've tried the following, which wasn't any faster after all:
  #
  #  1) use File::Slurp;
  #     my @lines = read_file( $srcFilename, binmode => ":encoding($defaultEncoding)" );
  #
  #  2) my @all = readline( $file );
  #
  #  3) Reading the whole file as a single string at once, in the hope that the UTF-8
  #     conversion was done faster on a whole single string:
  #
  #       binmode( $file, ":encoding($default_encoding)" )  # Also avoids CRLF conversion.
  #         or die "Cannot access file in binary mode or cannot set the file encoding: $!\n";
  #       my $read_res = read( $file, $file_content, $file_size );
  #
  #     And then I split the lines with:
  #
  #       my @all_lines = split( /\x0A/, $file_content );
  #
  # The one thing I haven't tried is a trick like the following, which turns a string into hex:
  #
  #   $file_content =~ s/(.)/sprintf("%x",ord($1))/eg;
  #
  # I could be possible to modify the regex and map the calls in some way so that the routine
  # gets called on each match, without modifying the original string.


  for ( my $lineNumber = 1; ; ++$lineNumber )
  {
    my $line = readline( $srcFile );

    last if not defined $line;

    # Strip trailing new-line characters.
    $line =~ s/[\n\r]+$//o;

    if ( 0 != length( $line ) )
    {
      # Function encode_entities() is rather slow, but I haven't found anything faster yet.
      # $line = "<code>" . encode_entities( $line ) . "</code>";
      encode_entities( $line );

      # Git shows and updates every second or so a progress message like this:
      #    Checking out files:   0% (2/38541)
      # These messages end with a Carriage Return (\r, 0x0D) only, without a Line Feed (\n, 0x0A) at the end,
      # and that's not displayed well in the HTML report. Therefore,
      # convert all embedded Carriage Return codes into HTML line breaks here.
      $line =~ s/\r/$htmlBr/og;
    }

    $line = "<tr>" .
            "<td class=\"linenumber\">$lineNumber</td>" .
            "<td class=\"logline\">$line</td>" .
            "</tr>\n";

    (print $destFile $line) or
      die "Cannot write to file \"$destFilename\": $!\n";
  }

  my $footer = "</tbody>\n" .
               "</table>\n" .
               "</body>\n" .
               "</html>\n";

  (print $destFile $footer) or
    die "Cannot write to file \"$destFilename\": $!\n";

  close_or_die( $destFile );
  close_or_die( $srcFile  );
}


sub generate_html_log_file_and_cell_links ( $ $ $ $ $ )
{
  my $logFilename     = shift;
  my $logsSubdir      = shift;
  my $defaultEncoding = shift;
  my $drillDownTarget = shift;  # Can be undef.
  my $htmlLogFileCreationSkippedAsItWasUpToDate = shift;

  my ( $volume, $directories, $logFilenameOnly ) = File::Spec->splitpath( $logFilename );

  my $htmlLogFilenameOnly .= $logFilenameOnly . ".html";

  my $htmlLogFilename = FileUtils::cat_path( $volume, $directories, $htmlLogFilenameOnly );


  # Skip the HTML log file creation if already up to date.

  $$htmlLogFileCreationSkippedAsItWasUpToDate = MiscUtils::FALSE;

  my ( $dev2, $ino2, $mode2, $nlink2, $uid2, $gid2, $rdev2, $size2,
       $atime2, $mtime2, $ctime2, $blksize2, $blocks2 ) = stat( $htmlLogFilename );

  if ( defined( $mtime2 ) )
  {
    my ( $dev1, $ino1, $mode1, $nlink1, $uid1, $gid1, $rdev1, $size1,
         $atime1, $mtime1, $ctime1, $blksize1, $blocks1 ) = stat( $logFilename );

    # If the text log file does not exist, let it fail later on during the conversion attempt.
    if ( defined( $mtime1 ) )
    {
      if ( $mtime2 >= $mtime1 )
      {
        $$htmlLogFileCreationSkippedAsItWasUpToDate = MiscUtils::TRUE;
      }
    }
  }

  if ( not $$htmlLogFileCreationSkippedAsItWasUpToDate )
  {
    convert_text_file_to_html( $logFilename, $htmlLogFilename, $defaultEncoding );
  }


  my $html = "";

  $html .= "<td>";

  if ( defined $drillDownTarget )
  {
    my $drillDownLink = encode_entities( $drillDownTarget );

    $html .= html_link( $drillDownLink, "Breakdown" );
    $html .= " or ";
  }

  my $logsSubdirEncoded = encode_entities( $logsSubdir );

  my $link1 = FileUtils::cat_path( $logsSubdirEncoded, encode_entities( $htmlLogFilenameOnly ) );
  my $link2 = FileUtils::cat_path( $logsSubdirEncoded, encode_entities( $logFilenameOnly     ) );
  $html .= html_link( $link1, "HTML" );
  $html .= " or ";
  $html .= html_link( $link2, "plain txt" );
  $html .= "</td>\n";

  return $html;
}


sub generate_status_cell ( $ )
{
  my $successful = shift;

  my $styleClass;
  my $text;

  if ( $successful )
  {
    $styleClass = "StatusOk";
    $text = "OK";
  }
  else
  {
    $styleClass = "StatusFailed";
    $text = "FAILED";
  }

  my $html = "";

  $html .= "<td class=\"$styleClass\">";
  $html .= $text;
  $html .= "</td>\n";
}


sub html_link ( $ $ )
{
  my $link = shift;
  my $text = shift;

  return "<a href=\"$link\">$text</a>";
}


1;  # The module returns a true value to indicate it compiled successfully.
