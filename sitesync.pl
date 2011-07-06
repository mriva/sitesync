#!/usr/bin/perl

# Need to add some comments

use strict;
use warnings;
use Config::General;
use Cwd;
use File::Path qw/make_path/;
use File::Listing qw/parse_dir/;
use Getopt::Std;
use Net::FTP;
use Term::ANSIColor;
use Term::ReadKey;
use Storable;

use Data::Dumper;
$Data::Dumper::Terse  = 1;
$Data::Dumper::Indent = 1;

my $RCFILENAME = $ENV{HOME} . '/.sitesyncrc';

if ( ! -f $RCFILENAME ) {
	open(my $fh, '>', $RCFILENAME) or die "Can't write config file\n";
	close $fh;
}

my $rcfile = new Config::General($RCFILENAME);
my %config = $rcfile->getall();

my ( $command, $site ) = parse_arguments();

my $is_interesting = get_filter_function();

my %dispatch = (
	n => \&site_new,
	l => \&site_list,
	i => \&site_info,
	r => \&site_remove,
	d => \&site_download,
	b => \&build_cache,
	t => \&test_run,
	x => \&site_diff,
	h => \&die_usage,
	DEFAULT => \&site_upload
);

defined $command ?
	$dispatch{$command}->() :
	$dispatch{DEFAULT}->();


# MAIN ACTIONS
sub site_new {
	local $| = 1;
	my $ftp;

	my $current_dir = cwd();
	my @path = grep { $_ ne '' } split /\//, $current_dir;
	my $hint = $path[-1];

	print "Bookmark [$hint]: ";
	chomp(my $bookmark = <STDIN>);
	$bookmark ||= $hint;

	$config{$bookmark}->{local_dir} = $current_dir.'/';

	while ( 1 ) {
		print "Remote site: ";
		chomp(my $site = <STDIN>);
		print "Verifying site... ";
		if ( $ftp = new Net::FTP($site, Debug => 0) ) {
			print colored ['green'], "OK\n";
			$config{$bookmark}->{remote_site} = $site;
			last;
		}
		print colored ['red'], "connection failed\n";
	}

	while ( 1 ) {
		print "FTP user: ";
		chomp(my $user = <STDIN>);

		print "FTP pass: ";
		ReadMode('noecho');
		chomp(my $pass = <STDIN>);
		ReadMode(0);

		print "\nTesting login... ";
		if ( $ftp->login($user, $pass) ) {
			print colored ['green'], "success\n";
			$config{$bookmark}->{ftp_user} = $user;
			$config{$bookmark}->{ftp_pass} = $pass;
			last;
		}
		print colored ['red'], "login failed\n";
	}

	print "Remote directory:\n";
	my $remote = pick_dir($ftp);

	exit unless defined $remote;

	$config{$bookmark}->{remote_dir} = $remote;

	save_config();
}
sub site_list {
	print join "\n", sort keys %config;
	print "\n";
}
sub site_info {
	print "[$site]\n";
	foreach my $key ( sort keys %{ $config{$site} } ) {
		my $val = $config{$site}{$key};
		$val = '*' x length($val) if $key eq 'ftp_pass';
		printf("  %-12s %-20s\n", $key, $val);
	}
	exit;
}
sub site_remove {
	print "Really remove $site? ";
	chomp(my $answer = <STDIN>);
	return if $answer ne 'y';

	delete $config{$site};
	save_config();

	print "$site deleted from config file\n";
}
sub site_download {
	print "Proceed with download? ";
	chomp(my $cmd = <STDIN>);
	exit unless $cmd eq 'y';

	my $sitedata = $config{$site};
	my $ftp = new Net::FTP($sitedata->{remote_site}) or die "Can't connect to remote server\n";
	$ftp->login($sitedata->{ftp_user}, $sitedata->{ftp_pass});

	my $data = remote_scan($ftp, $sitedata->{remote_dir});

	print "Downloading $site\n";

	foreach ( keys %{ $data->{dirs} } ) {
		( my $local = $_ ) =~ s/\Q$sitedata->{remote_dir}/$sitedata->{local_dir}/;
		print "$local\n";
		make_path($local) unless -d $local;
	}

	foreach ( keys %{ $data->{files} } ) {
		( my $local = $_ ) =~ s/\Q$sitedata->{remote_dir}/$sitedata->{local_dir}/;
		print "$local\n";
		$ftp->get($_, $local);
	}

	build_cache($site);
}
sub build_cache {
	store_cache(generate_cache());
}
sub test_run {
	print "Test.\n";

	my $sitedata = $config{$site};

	print Dumper generate_cache();
	exit;


	my $ftp = new Net::FTP($sitedata->{remote_site}) or die "Can't connect to remote server\n";
	$ftp->login($sitedata->{ftp_user}, $sitedata->{ftp_pass});

	my $cached = generate_cache();
	my $remote = remote_scan($ftp, $config{$site}{remote_dir});

#	print Dumper $remote;

	foreach ( keys %{ $cached->{files} } ) {
#		print $_; # $remote->{files}{$_}{time};
#		print $config{$site}{local_dir};
		( my $remote_path = $_ ) =~ s/\Q$config{$site}{local_dir}/$config{$site}{remote_dir}/;

		if ( $cached->{files}{$_}{size} != $remote->{files}{$remote_path}{size} ) {
			print "$_: size mismatch\n";
		}
	}
}
sub site_diff {
	my ( $files, $dirs ) = check_cache();
	return 0 unless @$files or @$dirs;

	if ( @$dirs ) {
		print "Dirs:\n";
		foreach ( @$dirs ) {
			print "N  $_\n";
		}
		print "\n";
	}

	if ( @$files ) {
		print "Files:\n";
		my $total = 0;
		foreach ( @$files ) {
			print "$_->[1]  $_->[0]\n";
			$total += $_->[2];
		}
		print "\n";
		print "Total: $total bytes\n";
	}

	1;
}
sub die_usage() {
	print <<EOT;
Usage: sitesync.pl [option] [sitename]

If no option is specified, "upload" is assumed, if no site is specified
current directory name (last segment) is used.

Options:

   -n      new site (interactive interface)
   -l      list registered sites
   -i      print site details
   -r      remove site from config file
   -d      download site structure from remote host
   -b      build cache as a snapshot from current local tree
   -x      shows what's changed from the cached snapshot
   -t      reserved for tests
   -h      display this information
EOT
	exit;
}
sub site_upload {
	my $dir = $config{$site}{local_dir};

	# check what's new
	if ( !site_diff() ) {
		die "Site $site unchanged\n";
	} else {
		print "Uploading $site\n\n";
	}

	# wait for input to proceed
	print "> ";
	chomp(my $cmd = <STDIN>);

	# autoflush
	local $| = 1;

	my $ftp = new Net::FTP($config{$site}->{remote_site}, Debug => 0)
		or die "Can't connect to remote server\n";
	print "Connected to $config{$site}->{remote_site}\n";
	
	$ftp->login($config{$site}->{ftp_user}, $config{$site}->{ftp_pass})
		or die "Can't login: invalid username/password\n";
	print "Logged in as $config{$site}->{ftp_user}\n";

	$ftp->binary();

	# get list of new or modified files and dirs (relative to stored cache)
	my ( $files, $dirs ) = check_cache();
	my ( @failed_dirs, @failed_files );

	foreach ( @$dirs ) {
		my $dirname = $config{$site}{remote_dir} . $_;
		print "Creating dir $dirname ... ";
		if ( !$ftp->mkdir($dirname, 1) ) {
			print colored ['red'], $ftp->message;
			push @failed_dirs, $config{$site}{local_dir} . $_;
		} else {
			print colored ['green'], "ok\n";
		}
	}

	foreach ( @$files ) {
		print "Uploading file: $_->[0] ... ";
		my $fullname = $config{$site}{local_dir} . $_->[0];
		if ( !$ftp->put($fullname, $config{$site}{remote_dir} . $_->[0]) ) {
			print colored ['red'], $ftp->message;
			push @failed_files, $config{$site}{local_dir} . $_->[0];
		} else {
			print colored ['green'], "ok\n";
		}
	}

	my $new_cache = generate_cache($site);

	# remove dirs and files that failed from the new cache
	# so they still be in the queue at next run
	foreach ( @failed_dirs ) {
		delete $new_cache->{dirs}{$_};
	}

	foreach ( @failed_files ) {
		delete $new_cache->{files}{$_};
	}

	store_cache($new_cache);
}

# HELPERS
sub generate_cache {
	my $dir = $config{$site}{local_dir};

	my $data = ( local_scan($dir) or {} );
}
sub store_cache {
	my $data = shift;
	my $filecache_dir = $config{$site}{local_dir} . '.ssync/';
	make_path($filecache_dir) unless -d $filecache_dir;
	my $filecache_name = $filecache_dir . 'filecache';
	
	store $data, $filecache_name;
}
sub check_cache {
	my $dir = $config{$site}{local_dir};
	my $filecache_name = $dir . '.ssync/filecache';

	my $local_data = local_scan($dir);

	my $cached_data;
	if ( -f $filecache_name ) {
		$cached_data = retrieve($filecache_name);
	} else {
		$cached_data = {};
	}

	my @files_to_upload = ();
	my @dirs_to_upload  = ();
	
	foreach ( keys %{ $local_data->{files} } ) {
		my $mod;

		if ( ! $cached_data->{files}{$_} ) {
			$mod = 'N';
		} elsif ( $cached_data->{files}{$_}{time} != $local_data->{files}{$_}{time} ) {
			$mod = 'T';
		} elsif ( $cached_data->{files}{$_}{size} != $local_data->{files}{$_}{size} ) {
			$mod = 'S';
		} else {
			next;
		}

		my $size = $local_data->{files}{$_}{size};
		s/$config{$site}{local_dir}//;
		push @files_to_upload, [$_, $mod, $size];
	}

	foreach ( keys %{ $local_data->{dirs} } ) {
		if ( ! $cached_data->{dirs}{$_} ) {
			s/$config{$site}{local_dir}//;
			push @dirs_to_upload, $_;
		}
	}

	return \@files_to_upload, \@dirs_to_upload;
}
sub pick_dir {
	my $ftp = shift;
	my $dir = '/';
	my $filter = '.';
	while ( 1 ) {
		# extract directories only
		my @list = parse_dir($ftp->dir($dir));
		my @directories = grep { /$filter/ } map { $_->[0] } grep { $_->[1] eq 'd' } @list;

		if ( $filter ne '.' ) {
			print "Filter: ";
			print colored ['green'], "/$filter/\n";
		}
		# UI
		for ( 1 .. @directories ) {
			printf("[%2s] %s\n", $_, $directories[$_ - 1]);
		}
		print "$dir\n";
		print "> ";
		chomp(my $response = <STDIN>);
		
		if ( $response =~ /^\d+$/ ) {
			$dir .= $directories[$response - 1] . '/' if defined $directories[$response - 1];
			$filter = '.';
		} elsif ( $response =~ m#\.\./?#) {
			$dir =~ s#[^/]+/$##;
			$filter = '.';
		} elsif ( $response =~ m#^f (.*)# ) {
			$filter = $1;
		} elsif ( $response eq 'r' ) {
			$filter = '.';
		} elsif ( $response eq 'x' ) {
			return $dir;
		} elsif ( $response eq 'q' ) {
			return;
		}
	}
}
sub remote_scan {
	my ($ftp, $dir, $data) = @_;
	my @list = parse_dir($ftp->dir($dir));

	for ( @list ) {
		my $name = $_->[0];
		my $type = $_->[1];

		next unless $is_interesting->($name);

		if ( $type eq 'd' ) {
			my $newdir = $dir.$name.'/';
			$data->{dirs}{$newdir} = 1;
			remote_scan($ftp, $newdir, $data);
		} else {
			@{ $data->{files}{$dir.$name} }{qw/size time/} = @$_[2,3];
		}
	}
	return $data;
}
sub local_scan {
	my ( $dir, $data ) = @_;
	opendir(my $dh, $dir) or die($@);
	while ( my $entry = readdir $dh ) {
		next unless $is_interesting->($entry);

		if ( -d $dir.$entry ) {
			my $newdir = $dir.$entry.'/';
			$data->{dirs}{$newdir} = 1;
			local_scan($newdir, $data);
		} else {
			# hash slice
			@{ $data->{files}{$dir.$entry} }{qw/size time/} = (stat $dir.$entry)[7,9];
		}
	}
	$data;
}
sub parse_arguments {
	die_usage() if @ARGV > 2;

	my %opts;
	getopts('nlirdbtxh', \%opts) or die_usage();

	my @actions = keys %opts;
	die_usage() if @actions > 1;

	my $command = shift @actions;

	my $site = $ARGV[0] ? $ARGV[0] : ( split /\//, cwd() )[-1];
	return $command, $site;
}
sub get_filter_function {
	return unless $config{$site};

	my $site_excludes_file = $config{$site}{local_dir} . '.ssync/exclude';
	my @site_excludes;
	if ( -f $site_excludes_file ) {
		open(my $fh, '<', $site_excludes_file);
		@site_excludes = map { chomp; qr/$_/ } <$fh>;
	}
	
	my @general_excludes = map { qr/$_/ } qw/^\.\.?$ \.swp$ \.upl$ \btemp\b \bmaterial[ie]\b \.(hg|ssync|svn)/;

	my @exclude_total = ( @site_excludes, @general_excludes );

	return sub {
		my $test = shift;
		return not grep { $test =~ /$_/ } @exclude_total;
	};
}
sub save_config {
	$rcfile->save_file($RCFILENAME, \%config);
}
