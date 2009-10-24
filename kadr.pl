#!/usr/bin/perl -w
# Copyright (c) 2008, clip9 <clip9str@gmail.com>

# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.

# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use strict;
use warnings;
use File::Copy;
use File::Find;
use Getopt::Long;
use Digest::MD4;
use db;

# TODO: convert all this to a single hash
# TODO: allow loading settings from a config file
my($username, $password, @scan_dirs, @watched_dirs, @unwatched_dirs, $watched_output_dir, $unwatched_output_dir);
my($ignore_anti_flood, $clean_scan_dirs, $clean_removed_files, $db_path) = (0, 1, 1, "kadr.db");
my($mylist_timeout, $mylist_watched_timeout, $file_timeout, $thread_count, $encoding) = (7200, 1036800, 1036800, 1, 'UTF8');
my($compression, $db_caching, $windows, $kde, $avdump, $reset_mylist_anime, $move, $purge_old_db_entries) = (1, 1, 0, 0, '', 0, 1, 1);
my $max_status_len = 1;
my $last_msg_len = 1;
my $last_msg_type = 0;
my $in_list_cache = bless {};


GetOptions(
	"username=s" => \$username,
	"password=s" => \$password,
	"scan-dirs=s{,}" => \@scan_dirs,
	"db:s" => \$db_path,
	"watched-dirs=s{,}" => \@watched_dirs,
	"unwatched-dirs=s{,}" => \@unwatched_dirs,
	"watched-output-dir=s" => \$watched_output_dir,
	"unwatched-output-dir=s" => \$unwatched_output_dir,
	"anidb-mylist-timeout=i" => \$mylist_timeout,
	"anidb-mylist-watched-timeout=i" => \$mylist_watched_timeout,
	"anidb-file-timeout=i" => \$file_timeout,
	"ignore-anti-flood" => \$ignore_anti_flood, # Allows it to ignore the 1 packet per 30 seconds rule, otherwise this rule is always followed, even when only a small number of commands are used. Intended to speed up short runs.
	"clean-scan-dirs!" => \$clean_scan_dirs, # Default = true. false disables deletion of empty folders in the scanned directories.
	"clean-removed-files!" => \$clean_removed_files, # Default is enabled. If enabled, set not found files that are on the database as deleted on anidb if they're still marked as on hdd.
	"encoding=s" => \$encoding,
	"compression!" => \$compression,
	"db-caching!" => \$db_caching, # Loads the entire db into memory. On a full run without any AniDB accesses (everything needed is cached) on about 4000 files, program runtime without is about 30-40 seconds, with is about 1.5-2 seconds.
	"windows!" => \$windows,
	"kde!" => \$kde, # Ignores .part files.
	"avdump=s" => \$avdump,
	"reset-mylist-anime!" => \$reset_mylist_anime, # Debug option. Default = false. true wipes all mylist_anime records from the cache, useful for when something breaks, and adbren-mod starts caching lots of invalid information.
	"move!" => \$move, # Debug option. Default = true. false does everything short of moving/renaming the files.
	"purge-old-db-entries!" => \$purge_old_db_entries, # Debug option. Default = true. false disables deletion of old cached records.
);

my $db = db->new("dbi:SQLite:$db_path");

if($purge_old_db_entries) {
	$db->{dbh}->do("DELETE FROM anidb_files WHERE updated < " . (time - $file_timeout));
	if($reset_mylist_anime) {
		$db->delete("anidb_mylist_anime", {});
	} else {
		$db->{dbh}->do("DELETE FROM anidb_mylist_anime WHERE updated < " . (time - $mylist_watched_timeout) . " AND watched_eps = eps_with_state_on_hdd");
		$db->{dbh}->do("DELETE FROM anidb_mylist_anime WHERE updated < " . (time - $mylist_timeout) . " AND watched_eps != eps_with_state_on_hdd");
	}
}

$db->cache([{table => "known_files", indices => ["filename", "size"]}, {table => "anidb_files", indices => ["ed2k"]}, {table => "anidb_mylist_file", indices => ["fid"]}, {table => "anidb_mylist_anime", indices => ["aid"]}]) if $db_caching;

my $a = AniDB::UDPClient->new({
	username  => $username,
	password  => $password,
	client    => "adbren",
	clientver => "5",
	db => $db,
	port => 3700,
	ignore_anti_flood => $ignore_anti_flood,
	encoding => $encoding,
	compression => $compression,
});

my @files;
my @ed2k_of_processed_files;
my $dirs_done = 1;
foreach(@scan_dirs) {
	next if !-e $_;
	printer($_, "Scanning", 0, $dirs_done++, scalar(@scan_dirs));
	@files = (@files, sort(recurse($_)));
}

my $fcount = scalar(@files);
my $file;
while ($file = shift @files) {
	next if $kde and $file =~ /\.part$/;
	if (my $ed2k = process_file($file, $a)) {
		push(@ed2k_of_processed_files, $ed2k);
	}
}

if ($clean_removed_files) {
	my @dead_files = sort { $::a->[2] cmp $::b->[2] } @{$db->{dbh}->selectall_arrayref("SELECT ed2k, size, filename FROM known_files WHERE ed2k NOT IN (" . join(',', map { "'$_'" } @ed2k_of_processed_files) . ");")};
	my($count, $dead_files_len) = (1, scalar(@dead_files) + 1);
	while($file = shift @dead_files) {
		printer($$file[2], "Cleaning", 0, $count, $dead_files_len);
		my $mylistinfo = $a->mylist_file_by_ed2k_size(@$file);
		if ( defined($mylistinfo) ) {
			if ($mylistinfo->{state} == 1) {
				printer($$file[2], "Removed", 1, $count, $dead_files_len);
				$a->mylistedit({lid => $mylistinfo->{lid}, state => 3});
			} else {
				printer($$file[2], "Cleaned", 1, $count, $dead_files_len);
			}
			$db->remove("anidb_mylist_file", {lid => $mylistinfo->{lid}});
		} else {
			printer($$file[2], "Not Found", 1, $count, $dead_files_len);
		}
		$db->remove("known_files", {ed2k => $$file[0]});
		$count++;
	}
}

$a->logout;
$db->{dbh}->disconnect();
STDOUT->printflush("\r" . ' ' x $last_msg_len . "\r");

if($clean_scan_dirs) {
	for(@scan_dirs) {
		finddepth({wanted => sub{rmdir}, follow => 1}, $_) if -e;
	}
}

sub recurse {
	my(@paths) = @_;
	my @files;
	for my $path (@paths) {
		opendir IMD, $path;
		for(readdir IMD) {
			if(!($_ eq '.' or $_ eq '..' or ($windows and $_ eq 'System Volume Information'))) {
				$_ = "$path/$_";
				if(-d $_) {
					push @paths, $_;
				} else {
					push @files, $_;
				}
			}
		}
		close IMD;
	}
	return @files;
}

sub process_file {
	my($file, $a) = @_;
	return if(not -e $file);
	printer($file, "Processing", 0);

	my $ed2k = ed2k_hash($file);
	my $fileinfo = $a->file_query({ed2k => $ed2k, size => -s $file});

	if(!defined $fileinfo) {
		printer($file, "Ignored", 1);
		return $ed2k;
	}

	# Auto-add to mylist.
	my $mylistinfo = $a->mylist_file_by_fid($fileinfo->{fid});
	if(!defined $mylistinfo) {
		printer($file, "Adding", 0);
		if (my $lid = $a->mylistadd($fileinfo->{fid})) {
			$db->update("anidb_files", {lid => $lid}, {fid => $fileinfo->{fid}});
			printer($file, "Added", 1);
		} else {
			printer($file, "Failed", 1);
		}
	} elsif ($mylistinfo->{state} != 1) {
		printer($file, "Updating", 0);
		if($a->mylistedit({lid => $fileinfo->{lid}, state => 1})) {
			$db->update("anidb_mylist_file", {state => 1}, {fid => $mylistinfo->{fid}});
			printer($file, "Updated", 1);
		} else {
			printer($file, "Failed", 1);
		}
	}
	
	my $mylistanimeinfo = $a->mylist_anime_by_aid($fileinfo->{aid});
	my $dir = array_find(substr($file, 0, rindex($file, '/')), @scan_dirs);
	my $file_output_dir = $dir;
	
	if(in_list($fileinfo->{episode}, $mylistanimeinfo->{watched_eps})) {
		$file_output_dir = $watched_output_dir unless array_contains($dir, @watched_dirs);
	} else {
		$file_output_dir = $unwatched_output_dir unless array_contains($dir, @unwatched_dirs);
	}

	if(defined $mylistanimeinfo and $mylistanimeinfo->{eps_with_state_on_hdd} !~ /^[a-z]*\d+$/i and !($fileinfo->{episode_number} eq $mylistanimeinfo->{eps_with_state_on_hdd}) and not ($file_output_dir eq $watched_output_dir and $fileinfo->{episode_number} eq $mylistanimeinfo->{watched_eps}) and not ($file_output_dir eq $unwatched_output_dir and count_list($mylistanimeinfo->{eps_with_state_on_hdd}) - count_list($mylistanimeinfo->{watched_eps}) == 1)) {
		my $anime_dir = $fileinfo->{anime_romaji_name};
		$anime_dir =~ s/\//∕/g;
		$file_output_dir .= "/$anime_dir";
		mkdir($file_output_dir) if !-e $file_output_dir;
	}
	
	my $file_version = $a->file_version($fileinfo);
	my $newname = $fileinfo->{anime_romaji_name} . ($fileinfo->{episode_english_name} =~ /^(Complete Movie|ova|special|tv special)$/i ? '' : " - " . $fileinfo->{episode_number} . ($file_version > 1 ? "v$file_version" : "") . " - " . $fileinfo->{episode_name}) . ((not $fileinfo->{group_short_name} eq "raw") ? " [" . $fileinfo->{group_short_name} . "]" : "") . "." . $fileinfo->{file_type};
	
	$newname = $fileinfo->{anime_romaji_name} . " - " . $fileinfo->{episode_number} . " - Episode " . $fileinfo->{episode_number} . ((not $fileinfo->{group_short_name} eq "raw") ? " [" . $fileinfo->{group_short_name} . "]" : "") . "." . $fileinfo->{file_type} if length($newname) > 250;
	
	$newname =~ s/\//∕/g; # unix doesn't like / in filenames
	$newname =~ s/[\\\\:\*"><\|\?]/_/g if $windows;

	unless($file eq "$file_output_dir/$newname") {
		if(-e "$file_output_dir/$newname") {
			print "\nRename from:   $file\nFailed to: $file_output_dir/$newname\n";
		} else {
			printer($file, "File", 1);
			if($move) {
				printer("$file_output_dir/$newname", "Moving to", 0);
				$db->update("known_files", {filename => $newname}, {ed2k => $ed2k, size => -s $file});
				move($file, "$file_output_dir/$newname");
				printer("$file_output_dir/$newname", "Moved to", 1);
			} else {
				printer("$file_output_dir/$newname", "Would have moved to", 1);
			}
			
		}
	}

	return $fileinfo->{ed2k};
}

sub array_contains { defined array_find(@_) }

sub array_find {
	my($key, @haystack) = @_;
	foreach my $straw (@haystack) {
		return $straw if index($key, $straw) > -1;
	}
	return undef;
}

sub avdump {
	my($file, $ed2k, $size) = @_;
	printer($file, "Avdumping", 0);
	(my $esc_file = $file) =~ s/(["'`])/\\$1/s; # I never quite figured out how to get it to avdump files with quotation marks in the names.
	system "$avdump -as -tout:20:6555 \"$esc_file\" > /dev/null";
	$db->update("known_files", {avdumped => 1}, {ed2k => $ed2k, size => $size});
	printer($file, "Avdumped", 1);
}

sub ed2k_hash {
	my($file) = @_;
	my $file_sn = substr($file, rindex($file, '/') + 1, length($file));
	my $size = -s $file;
	my($ed2k, $avdumped);
	my $r = $db->fetch("known_files", ["ed2k", "avdumped"], {filename => $file_sn, size => $size}, 1, "array");
	if(defined $r) {
		($ed2k, $avdumped) = ($r->{ed2k}, $r->{avdumped});
		avdump($file, $ed2k, $size) if $avdump and !$avdumped;
		return $ed2k;
	}
	
	$ed2k = calc_ed2k_hash($file);
	$db->insert("known_files", {filename => $file_sn, size => $size, ed2k => $ed2k});
	avdump($file, $ed2k, $size) if $avdump;
	return $ed2k;
}

sub calc_ed2k_hash {
	my($file) = @_;
	my $ed2k;
	my $ctx    = Digest::MD4->new;
	my $ctx2   = Digest::MD4->new;
	my $buffer;
	open my $handle, "<", $file or die $!;
	binmode $handle;

	my $block  = 0;
	my $b      = 0;
	my $length = 0;
	my $donelen= 0;
	my $size = -s $file;
	while($length = read $handle, $buffer, 102400) {
		while($length < 102400) {
			my $missing = 102400 - $length;
			my $missing_buffer;
			my $missing_read = read $handle, $missing_buffer, $missing;
			$length += $missing_read;
			last if !$missing_read;
			$buffer .= $missing_buffer;
		}
		$ctx->add($buffer);
		$b++;
		$donelen += $length;
		if($b % 100) {
			my $progress = ($donelen / $size) * 100;
			printer($file, "Hashing " . substr($progress, 0, index($progress, '.') + 2) . "%", 0);
		}

		if($b == 95) {
			$ctx2->add($ctx->digest);
			$b = 0;
			$block++;
		}
	}
	close($handle);
	printer($file, "Hashed", 1);
	return $ctx->hexdigest if $block == 0;
	return $ctx2->hexdigest if $b == 0;
	$ctx2->add($ctx->digest);
	return $ctx2->hexdigest;
}

sub printer {
	my($file, $status, $type, $progress, $total) = @_;
	my $status_len = length($status);
	$max_status_len = $status_len if $status_len > $max_status_len;
	my $msg = "[" . (defined $progress ? $progress : ($fcount - scalar(@files))) . "/" . (defined $total ? $total : $fcount) . "][$status]" . (" " x ($max_status_len - $status_len + 1)) . $file;
	STDOUT->printflush(($last_msg_type ? "\n" : ("\r" . (length($msg) < $last_msg_len ? (' ' x $last_msg_len) . "\r" : ''))) . $msg);
	$last_msg_len = length($msg);
	$last_msg_type = $type;
}

# Determines if the specified number is in a AniDB style list of episode numbers.
# Example: in_List(2, "1-3") == true
sub in_list {
	my($needle, $haystack) = @_;
	#print "\nneedle: $needle\t haystack: $haystack\n";
	if($needle =~ /^(\w+)-(\w+)$/) {
		return in_list($1, $haystack);
		# This is commented out to work around a bug in the AniDB UDP API.
		# For multi-episode files, the API only includes the first number in the lists that come in MYLIST commands.
		#for ($first..$last) {
		#	return 0 if !in_list($_, $haystack);
		#}
		#return 1;
	}
	
	$needle =~ s/^(\w*?)[0]*(\d+)$/$1$2/;
	#print "ineedle: $needle\t haystack: $haystack\n";
	cache_list($haystack);
	return(defined $in_list_cache->{$haystack}->{$needle} ? 1 : 0);
}

sub count_list {
	my ($list) = @_;
	cache_list($list);
	return scalar(keys(%{$in_list_cache->{$list}}));
}

sub cache_list {
	my($list) = @_;
	if(!defined $in_list_cache->{$list}) {
		for(split /,/, $list) {
			if($_ =~ /^(\w+)-(\w+)$/) {
				for my $a (range($1, $2)) {
					$in_list_cache->{$list}->{$a} = 1;
				}
			} else {
				$in_list_cache->{$list}->{$_} = 1;
			}
		}
	}
}

sub range {
	my($start, $end) = @_;
	$start =~ s/^([a-xA-Z]*)(\d+)$/$2/;
	my $tag = $1;
	$end =~ s/^([a-xA-Z]*)(\d+)$/$2/;
	map { "$tag$_" } $start .. $end;
}

package AniDB::UDPClient;
use strict;
use warnings;
use IO::Socket;
use Scalar::Util qw(reftype);

# Threshhold values are specified in packets.
use constant SHORT_TERM_FLOODCONTROL_ENFORCEMENT_THRESHHOLD => 5;
use constant LONG_TERM_FLOODCONTROL_ENFORCEMENT_THRESHHOLD => 100;

#acodes:
use constant GROUP_NAME          => 0x00000001;
use constant GROUP_NAME_SHORT    => 0x00000002;
use constant EPISODE_NUMBER      => 0x00000100;
use constant EPISODE_NAME        => 0x00000200;
use constant EPISODE_NAME_ROMAJI => 0x00000400;
use constant EPISODE_NAME_KANJI  => 0x00000800;
use constant EPISODE_TOTAL       => 0x00010000;
use constant EPISODE_LAST        => 0x00020000;
use constant ANIME_YEAR          => 0x00040000;
use constant ANIME_TYPE          => 0x00080000;
use constant ANIME_NAME_ROMAJI   => 0x00100000;
use constant ANIME_NAME_KANJI    => 0x00200000;
use constant ANIME_NAME_ENGLISH  => 0x00400000;
use constant ANIME_NAME_OTHER    => 0x00800000;
use constant ANIME_NAME_SHORT    => 0x01000000;
use constant ANIME_SYNONYMS      => 0x02000000;
use constant ANIME_CATEGORY      => 0x04000000;

#fcodes:
use constant AID           => 0x00000002;
use constant EID           => 0x00000004;
use constant GID           => 0x00000008;
use constant LID           => 0x00000010;
use constant STATUS        => 0x00000100;
use constant SIZE          => 0x00000200;
use constant ED2K          => 0x00000400;
use constant MD5           => 0x00000800;
use constant SHA1          => 0x00001000;
use constant CRC32         => 0x00002000;
use constant LANG_DUB      => 0x00010000;
use constant LANG_SUB      => 0x00020000;
use constant QUALITY       => 0x00040000;
use constant SOURCE        => 0x00080000;
use constant CODEC_AUDIO   => 0x00100000;
use constant BITRATE_AUDIO => 0x00200000;
use constant CODEC_VIDEO   => 0x00400000;
use constant BITRATE_VIDEO => 0x00800000;
use constant RESOLUTION    => 0x01000000;
use constant FILETYPE      => 0x02000000;
use constant LENGTH        => 0x04000000;
use constant DESCRIPTION   => 0x08000000;

use constant FILE_STATUS_CRCOK  => 0x01;
use constant FILE_STATUS_CRCERR => 0x02;
use constant FILE_STATUS_ISV2   => 0x04;
use constant FILE_STATUS_ISV3   => 0x08;
use constant FILE_STATUS_ISV4   => 0x10;
use constant FILE_STATUS_ISV5   => 0x20;
use constant FILE_STATUS_UNC    => 0x40;
use constant FILE_STATUS_CEN    => 0x80;

use constant FILE_FCODE => "7ff87ff8";
use constant FILE_ACODE => "fefcfcc0";

use constant CODE_220_ENUM => 
qw/aid eid gid lid other_episodes is_deprecated status
   size ed2k md5 sha1 crc32
   quality source audio_codec audio_bitrate video_codec video_bitrate video_resolution file_type
   dub_language sub_language length description air_date
   anime_total_episodes anime_highest_episode_number anime_year anime_type anime_related_aids anime_related_aid_types anime_categories
   anime_romaji_name anime_kanji_name anime_english_name anime_other_name anime_short_names anime_synonyms
   episode_number episode_english_name episode_romaji_name episode_kanji_name episode_rating episode_vote_count
   group_name group_short_name/;

use constant FILE_ENUM => qw/fid aid eid gid lid status_code size ed2k md5 sha1
  crc32 lang_dub lang_sub quality source audio_codec audio_bitrate video_codec
  video_bitrate resolution filetype length description group group_short
  episode episode_name episode_name_romaji episode_name_kanji episode_total
  episode_last anime_year anime_type anime_name_romaji anime_name_kanji
  anime_name_english anime_name_other anime_name_short anime_synonyms
  anime_category/;

use constant FILE_CODE =>
		AID | EID | GID | LID | STATUS | SIZE | ED2K | MD5 | SHA1 | CRC32 |
		LANG_DUB | LANG_SUB | QUALITY | SOURCE | CODEC_AUDIO | BITRATE_AUDIO |
		CODEC_VIDEO | BITRATE_VIDEO | RESOLUTION | FILETYPE | LENGTH |
		DESCRIPTION;
use constant ANIME_CODE =>
		GROUP_NAME | GROUP_NAME_SHORT | EPISODE_NUMBER | EPISODE_NAME |
		EPISODE_NAME_ROMAJI | EPISODE_NAME_KANJI | EPISODE_TOTAL | EPISODE_LAST |
		ANIME_YEAR | ANIME_TYPE | ANIME_NAME_ROMAJI | ANIME_NAME_KANJI |
		ANIME_NAME_ENGLISH | ANIME_NAME_OTHER | ANIME_NAME_SHORT |
		ANIME_SYNONYMS | ANIME_CATEGORY;

use constant MYLIST_FILE_ENUM => qw/lid fid eid aid gid date state viewdate storage source other filestate/;

use constant MYLIST_ANIME_ENUM => qw/anime_title episodes eps_with_state_unknown eps_with_state_on_hdd eps_with_state_on_cd eps_with_state_deleted watched_eps/;

sub new {
	my $self = bless {}, shift;
	parse_args($self, @_);

	defined $self->{username}  or die "Username not defined!\n";
	defined $self->{password}  or die "Password not defined!\n";
	defined $self->{client}    or die "Client not defined!\n";
	defined $self->{clientver} or die "Clientver not defined!\n";
	$self->{starttime} = time - 1;
	$self->{queries} = 0;
	$self->{last_command} = 0;
	$self->{handle}   = IO::Socket::INET->new(Proto => 'udp', LocalPort => $self->{port}) or die($!);
	$self->{ipaddr}   = gethostbyname("api.anidb.info") or die("Gethostbyname('api.anidb.info'):" . $!);
	$self->{sockaddr} = sockaddr_in(9000, $self->{ipaddr}) or die($!);
	if($self->{compression}) {
		use IO::Uncompress::Inflate qw(inflate $InflateError);
	}
	return $self;
}

sub parse_args {
	my($mod, @args, @names) = @_;
	map { $mod->{$_} = $args[0]->{$_} } keys %{$args[0]} and shift @args if reftype($args[0]) eq 'HASH';
	map { $mod->{$_} = shift @args if scalar @args } @names;
}

sub file_by_ed2k_size {
	my ($self, $ed2k, $size) = @_;
	
	my $fileinfo = $self->{db}->fetch("anidb_files", ["*"], {ed2k => $ed2k}, 1);
	return $fileinfo if defined $fileinfo;
	return $self->_file_query({size => $size, ed2k => $ed2k});
}

sub file_by_fid {
	my($self, $fid) = @_;

	my $fileinfo = $self->{db}->fetch("anidb_files", ["*"], {fid => $fid}, 1);
	return $fileinfo if defined $fileinfo;
	return $self->_file_query({fid => $fid});
}

sub _file_query {
	my($self, $query) = @_;
	$query->{acode} = ANIME_CODE;# + 134217728 + 268435456 + 536870912;
	$query->{fcode} = FILE_CODE;
	
	my $msg = $self->_sendrecv("FILE", $query);
	$msg =~ s/.*\n//im;
	my @f = split /\|/, $msg;

	if(scalar @f > 0) {
		my %fileinfo;
		map { $fileinfo{(FILE_ENUM)[$_]} = $f[$_] } 0 .. $#f;
		$fileinfo{anime_name_short} =~ s/'/,/g;
		$fileinfo{anime_synonyms}   =~ s/'/,/g;
		
		if($fileinfo{status_code} & FILE_STATUS_CEN) {
			$fileinfo{censored} = "cen";
		} elsif($fileinfo{status_code} & FILE_STATUS_UNC) {
			$fileinfo{censored} = "unc";
		}
		
		if($fileinfo{status_code} & FILE_STATUS_ISV2) {
			$fileinfo{version} = "v2";
		} elsif($fileinfo{status_code} & FILE_STATUS_ISV3) {
			$fileinfo{version} = "v3";
		} elsif($fileinfo{status_code} & FILE_STATUS_ISV4) {
			$fileinfo{version} = "v4";
		} elsif($fileinfo{status_code} & FILE_STATUS_ISV5) {
			$fileinfo{version} = "v5";
		}
		
		$fileinfo{crcok} = $fileinfo{status_code} & FILE_STATUS_CRCOK;
		$fileinfo{crcerr} = $fileinfo{status_code} & FILE_STATUS_CRCERR;
		$fileinfo{anime_name_english} = $fileinfo{anime_name_romaji} if not defined $fileinfo{anime_name_english} or $fileinfo{anime_name_english} eq '';
		$fileinfo{anime_name_romaji} = $fileinfo{anime_name_english} if not defined $fileinfo{anime_name_romaji} or $fileinfo{anime_name_romaji} eq '';
		return undef if not defined $fileinfo{anime_name_romaji} and not defined $fileinfo{anime_name_english};
		
		$fileinfo{updated} = time;
		$self->{db}->set('anidb_files', \%fileinfo, {fid => $fileinfo{fid}});
		return \%fileinfo;
	}
	return undef;
}

sub file_query {
	my($self, $query) = @_;
	
	return $_ if $self->{db}->fetch("anidb_files", ["*"], $query, 1);
	
	$query->{fcode} = FILE_FCODE;
	$query->{acode} = FILE_ACODE;
	
	my($code, $data) = split("\n", decode_utf8($self->_sendrecv("FILE", $query)));
	
	$code = int((split(" ", $code))[0]);
	if($code == 220) { # Success
		my %fileinfo;
		my @fields = split /\|/, $data;
		map { $fileinfo{(CODE_220_ENUM)[$_]} = $fields[$_] } 0 .. scalar(CODE_220_ENUM) - 1;
		
		$fileinfo{updated} = time;
		$self->{db}->set('adbcache_file', \%fileinfo, {fid => $fileinfo{fid}});
		return \%fileinfo;
	} elsif($code == 322) { # Multiple files found.
		die "Error: \"322 MULITPLE FILES FOUND\" not supported.";
	} elsif($code == 320) { # No such file.
		return undef;
	}
}

sub file_version {
	my($self, $file) = @_;
	
	if($file->{status} & FILE_STATUS_ISV2) {
		return 2;
	} elsif($file->{status} & FILE_STATUS_ISV3) {
		return 3;
	} elsif($file->{status} & FILE_STATUS_ISV4) {
		return 4;
	} elsif($file->{status} & FILE_STATUS_ISV5) {
		return 5;
	} else {
		return 1;
	}
}

sub mylistadd {
	my $res = shift->mylist_add_query({state => 1, fid => shift});
	return $res;
}

sub mylistedit {
	my ($self, $params) = @_;
	$params->{edit} = 1;
	return $self->mylist_add_query($params);
}

sub mylist_add_query {
	my ($self, $params) = @_;
	my $res;

	if ((!defined $params->{edit}) or $params->{edit} == 0) {
		# Add

		$res = $self->_sendrecv("MYLISTADD", $params);

		if ($res =~ /^210 MYLIST/) { # OK
			return (split(/\n/, $res))[1];
		} elsif ($res !~ /^310/) { # any errors other than 310
			return 0;
		}
		# If 310 ("FILE ALREADY IN MYLIST"), retry with edit=1
		$params->{edit} = 1;
	}
	# Edit

	$res = $self->_sendrecv("MYLISTADD", $params);

	if ($res =~ /^311/) { # OK
		return (split(/\n/, $res))[1];
	}
	return 0; # everything else
}

sub mylist_file_by_fid {
	my($self, $fid) = @_;

	my $mylistinfo = $self->{db}->fetch("anidb_mylist_file", ["*"], {fid => $fid}, 1);
	return $mylistinfo if defined $mylistinfo;
	# Due to the current design, if me need to get this record from AniDB, it's a new file, so we should update the mylist_anime record at the same time. Deleting the old record will atuomatically force it to fetch if from the server again.
	my $fileinfo = $self->file_by_fid($fid);
	$self->{db}->remove("anidb_mylist_anime", {aid => $fileinfo->{aid}});
	return $self->_mylist_file_query({fid => $fid});;
}

sub mylist_file_by_lid {
	my($self, $lid) = @_;

	my $mylistinfo = $self->{db}->fetch("anidb_mylist_file", ["*"], {lid => $lid}, 1);
	return $mylistinfo if defined $mylistinfo;

	return $self->_mylist_file_query({lid => $lid});
}

sub mylist_file_by_ed2k_size {
	my ($self, $ed2k, $size) = @_;

	my $fileinfo = $self->{db}->fetch("adbcache_file", ["*"], {size => $size, ed2k => $ed2k}, 1);
	if(defined($fileinfo)) {
		return undef if !$fileinfo->{lid};
		
		$self->{db}->remove("anidb_mylist_file", {lid => $fileinfo->{lid}});
		return $self->mylist_file_by_lid($fileinfo->{lid});
	}
	return $self->_mylist_file_query({size => $size, ed2k => $ed2k});
}

sub _mylist_file_query {
	my($self, $query) = @_;
	(my $msg = $self->_sendrecv("MYLIST", $query)) =~ s/.*\n//im;
	my @f = split /\|/, $msg;
	if(scalar @f) {
		my %mylistinfo;
		map { $mylistinfo{(MYLIST_FILE_ENUM)[$_]} = $f[$_] } 0 .. $#f;
		$mylistinfo{updated} = time;
		$self->{db}->set('anidb_mylist_file', \%mylistinfo, {lid => $mylistinfo{lid}});
		return \%mylistinfo;
	}
	undef;
}

sub mylist_anime_by_aid {
	my($self, $aid) = @_;
	my $mylistanimeinfo = $self->{db}->fetch("anidb_mylist_anime", ["*"], {aid => $aid}, 1);
	return $mylistanimeinfo if defined $mylistanimeinfo;
	return $self->_mylist_anime_query({aid => $aid});
}

sub _mylist_anime_query {
	my($self, $query) = @_;
	my $msg = $self->_sendrecv("MYLIST", $query);
	my $single_episode = ($msg =~ /^221/);
	my $success = ($msg =~ /^312/);
	return undef if not ($success or $single_episode);
	$msg =~ s/.*\n//im;
	my @f = split /\|/, $msg;
	
	if(scalar @f) {
		my %mylistanimeinfo;
		$mylistanimeinfo{aid} = $query->{aid};
		if($single_episode) {
			my %mylistinfo;
			map { $mylistinfo{(MYLIST_FILE_ENUM)[$_]} = $f[$_] } 0 .. $#f;
			
			my $fileinfo = $self->file_by_fid($mylistinfo{fid});
			
			$mylistanimeinfo{anime_title} = $fileinfo->{anime_name_romaji};
			$mylistanimeinfo{episodes} = '';
			$mylistanimeinfo{eps_with_state_unknown} = "";
			
			if($fileinfo->{episode} =~ /^(\w*?)[0]*(\d+)$/) {
				$mylistanimeinfo{eps_with_state_on_hdd} = "$1$2";
				$mylistanimeinfo{watched_eps} = ($mylistinfo{viewdate} > 0 ? "$1$2" : "");
			} else {
				$mylistanimeinfo{eps_with_state_on_hdd} = $fileinfo->{episode};
				$mylistanimeinfo{watched_eps} = ($mylistinfo{viewdate} > 0 ? $fileinfo->{episode} : "");
			}
			$mylistanimeinfo{eps_with_state_on_cd} = "";
			$mylistanimeinfo{eps_with_state_deleted} = "";
		} else {
			map { $mylistanimeinfo{(MYLIST_ANIME_ENUM)[$_]} = $f[$_] } 0 .. scalar(MYLIST_ANIME_ENUM) - 1;
		}
		$mylistanimeinfo{updated} = time;
		$self->{db}->set('anidb_mylist_anime', \%mylistanimeinfo, {aid => $mylistanimeinfo{aid}});
		return \%mylistanimeinfo;
	}
	return undef;
}

sub login {
	my($self) = @_;
	if(!defined $self->{skey} || (time - $self->{last_command}) > (35 * 60)) {
		my $msg = $self->_sendrecv("AUTH", {user => lc($self->{username}), pass => $self->{password}, protover => 3, client => $self->{client}, clientver => $self->{clientver}, nat => 1, enc => $encoding, comp => $compression});
		if(defined $msg && $msg =~ /20[01]\ ([a-zA-Z0-9]*)\ ([0-9\.\:]).*/) {
			$self->{skey} = $1;
			$self->{myaddr} = $2;
		} else {
			die "Login Failed: $msg\n";
		}
	}
	return 1;
}

sub logout {
	my($self) = @_;
	$self->_sendrecv("LOGOUT") if $self->{skey};
}

# Sends and reads the reply. Tries up to 10 times.
sub _sendrecv {
	my($self, $query, $vars) = @_;
	my $recvmsg;
	my $attempts = 0;
	
	$self->login if $query ne "AUTH" && (!defined $self->{skey} || (time - $self->{last_command}) > (35 * 60));

	$vars->{'s'} = $self->{skey} if $self->{skey};
	$vars->{'tag'} = "T" . $self->{queries};
	$query .= ' ' . join('&', map { "$_=$vars->{$_}" } keys %{$vars}) . "\n";

	while(!$recvmsg) {
		if($self->{queries} > LONG_TERM_FLOODCONTROL_ENFORCEMENT_THRESHHOLD) {
			if(!$self->{ignore_anti_flood}) {
				while ($self->{queries} / (time - $self->{starttime}) > 0.033) {}
			}
		} elsif($self->{queries} > SHORT_TERM_FLOODCONTROL_ENFORCEMENT_THRESHHOLD) {
			while($self->{last_command} + 2 > time) {}
		}
		
		$self->{last_command} = time;
		$self->{queries} += 1;
		
		send($self->{handle}, $query, 0, $self->{sockaddr}) or die( "Send error: " . $! );
		
		my $rin = '';
		my $rout;
		vec($rin, fileno($self->{handle}), 1) = 1;
		recv($self->{handle}, $recvmsg, 1500, 0) or die("Recv error:" . $!) if select($rout = $rin, undef, undef, 30.0);
		
		$attempts++;
		die "\nTimeout while waiting for reply.\n" if $attempts == 4;
        }

	# Check if the data is compressed.
	if(substr($recvmsg, 0, 2) eq "\x00\x00") {
		my $data = substr($recvmsg, 2);
		inflate \$data => \$recvmsg or return undef;
	}

	# Check that the answer we received matches the query we sent.
	$recvmsg =~ s/^(T\d+) (.*)/$2/;
	if($1 ne $vars->{tag}) {
		die "Tag mismatch";
	}

	# Check if our session is invalid.
	if($recvmsg =~ /^501.*|^506.*/) {
		undef $self->{skey};
		$self->login();
		return $self->_sendrecv($query, $vars);
	}
	
	# Check for a server error.
	if($recvmsg =~ /^6\d+.*$/ or $recvmsg =~ /^555/) {
		die("\nAnidb error:\n$recvmsg");
	}
	
	return $recvmsg;
}