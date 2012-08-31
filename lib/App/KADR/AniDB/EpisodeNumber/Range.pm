package App::KADR::AniDB::EpisodeNumber::Range;
use v5.10;
use common::sense;
use overload
	fallback => 1,
	'""' => 'stringify';
use Scalar::Util qw(blessed looks_like_number);

use App::KADR::AniDB::EpisodeNumber;

my %cache;
my $tag_range_re = qr/^ ([a-xA-Z]*) (\d+) (?: - \g{1} (\d+) )? $/x;

sub intersection {
	my ($self, $other) = @_;

	# Return something sane if this range gets called with something other than another range.
	return App::KADR::AniDB::EpisodeNumber->new($self)->intersection($other)
		unless blessed $other && $other->isa(__PACKAGE__);

	return if $self->{tag} ne $other->{tag};

	# Implement Number::Tolerant::intersection ourself since it Carp::confess'es our performance away. T_T
	my ($min) = sort {$b<=>$a} $self->{min}, $other->{min};
	return unless defined $min;

	my ($max) = sort {$a<=>$b} $self->{max}, $other->{max};

	return if !defined $max || $max < $min || $min > $max;

	$self->new($min, $max, $self->{tag})
}

sub new {
	# my ($class, $min, $max, $tag) = @_;
	return unless my $min = int $_[1];
	($min, my $max) = sort { $a <=> $b } $min, int($_[2]) || $min;

	$cache{$_[3]}->{$min}{$max} //= do {
		my $class = ref $_[0] || $_[0];
		bless {min => $min, max => $max, tag => $_[3]}, $class;
	};
}

sub parse {
	my ($class, $string) = @_;
	$class = ref $class if ref $class;

	return $class->new($2, $3, $1)
		if $string =~ $tag_range_re;
	return;
}

sub stringify {
	$_[0]{stringify} //= $_[0]{tag} . $_[0]{min} . ($_[0]{max} > $_[0]{min} ? '-' . $_[0]{tag} . $_[0]{max} : '');
}

0x6B63;
