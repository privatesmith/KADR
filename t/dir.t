use App::KADR::Path -all;
use common::sense;
use File::HomeDir;
use FindBin;
use Test::More;

my $home   = dir(File::HomeDir->my_home);
my $bindir = dir($FindBin::Bin);

subtest 'abs_cmp' => sub {
	ok $home != undef;
	ok $home eq File::HomeDir->my_home;
	ok $home != file(File::HomeDir->my_home);
	ok $home eq dir(File::HomeDir->my_home);
	ok $home == dir(File::HomeDir->my_home);
	ok $home ne $bindir;
	ok $home != $bindir;
	ok $bindir ne $bindir->relative($home);
	ok $bindir != $bindir->relative($home);
	ok $bindir == $bindir->relative;
	ok $bindir->relative == $bindir;
	ok $bindir->relative != $bindir->relative($home);
};

done_testing;
