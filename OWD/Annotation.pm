package OWD::Annotation;
use strict;
use List::MoreUtils;
use Carp;
use Log::Log4perl;
use Data::Dumper;

my $logger = Log::Log4perl->get_logger();

my $debug = 1;

my $valid_doctypes = {
	'cover'		=> 1,
	'blank'		=> 1,
	'diary'		=> 1,
	'other'		=> 1,
	'orders'	=> 1,
	'signals'	=> 1,
	'report'	=> 1,
};

my $valid_annotation_types = {
	'doctype'	=> 1,
	'diaryDate'	=> 1,
	'activity'	=> 1,
	'time'		=> 1,
	'domestic'	=> 1,
	'casualties'=> 1,
	'weather'	=> 1,
	'strength'	=> 1,
	'orders'	=> 1,
	'signals'	=> 1,
	'reference'	=> 1,
	'title'		=> 1,
	'date'		=> 1,
	'mapRef'	=> 1,
	'gridRef'	=> 1,
	'strength'	=> 1,
};

my $valid_note_fields = {
	'place'	=> { 
				country		=> 1,
				id 			=> 1,
				lat			=> 1,
				location	=> 1,
				long		=> 1,
				name		=> 1,
				place		=> 1,
				placeOption	=> 1,
	},
};

my @countries = qw/ France Germany Belgium Holland Netherlands /;
 
my @military_suffixes = (
	"A\.? ?S\.? ?C", 			"C\.? ?M\.? ?B",			"C\.? ?M\.? ?G",
	"D\.? ?C\.? ?M",			"D.? ?O",					"D\.? ?O\.? ?M",								
	"D\.? ?S\.? ?O",			"K\.? ?C\.? ?B",			"\\(\\?Lt\\)?",
	"M\.? ?C",					"M\.? ?M",					"M\.? ?O",
	"M\.? ?O\.? ?R\.? ?C",	 	"R\.?A\.?",					"R\.? ?A\.? ?M\.? ?C",
	"R\.? ?E",					"R\.? ?F\.? ?A",
	"R\.? ?M",									
);

my %month = (
	"Jan" => 1,
	"Feb" => 2,
	"Mar" => 3,
	"Apr" => 4,
	"May" => 5,
	"Jun" => 6,
	"Jul" => 7,
	"Aug" => 8,
	"Sep" => 9,
	"Oct" => 10,
	"Nov" => 11,
	"Dec" => 12,
);

my @days_in_month = qw/ 0 31 29 31 30 31 30 31 31 30 31 30 31 /;

my $military_suffixes_regex = join '\b|\b', @military_suffixes;
$military_suffixes_regex = "\\b$military_suffixes_regex\\b";

my $free_text_fields = { 
	"place:place" 		=> 1,
	"person:first" 		=> 1,
	"person:surname"	=> 1,
	"person:unit"		=> 1,
	"unit:name"			=> 1,
	"gridRef:gridref_a"	=> 1,
	"gridRef:gridref_b"	=> 1,
	"gridRef:gridref_c"	=> 1,
	"gridRef:gridref_d"	=> 1,
	"gridRef:gridref_e"	=> 1,
};

sub new {
	my ($class, $_classification, $_annotation) = @_;
	$logger->trace("OWD::Annotation->new() called on $_annotation->{id}");
	# some "cleaning" needs to be done to the raw data to improve chances of consensus
	# - extraneous spacing and punctuation were sometimes added by users in free text fields
	# - bugs in the application allowed things like inconsistent date formats, invalid dates, 
	# - different but valid ways of representing the same thing (like unit full names vs abbreviations)
	# - users finding different ways of representing uncertainty (eg inserting question marks in place of illegible characters)

	my $obj = bless {
		'_classification'		=> $_classification,
		'_annotation_data'		=> $_annotation,
	}, $class;
	
	# validate first - check for missing fields or invalid data that can't be fixed.
	if ($obj->_data_consistent()) {
		# create a "standardised_note" field, initialised from the raw data note field.
		# any modifications we make to "fix" user errors and improve the likeliood of consensus
		# will be made to the standardised_note field so that we preserve what was actually entered 
		# by the user in the original note field.
		if (ref($obj->{_annotation_data}{note}) eq 'HASH') {
			my %note = %{$obj->{_annotation_data}{note}};
			$obj->{_annotation_data}{standardised_note} = \%note;
		}
		else {
			$obj->{_annotation_data}{standardised_note} = $obj->{_annotation_data}{note};
		}
		
		# Do something to standardise mentions of the King. He is mentioned a few times, but the fields
		# available for tagging a "person" don't offer much chance of consistency for someone whose name
		# and rank don't follow usual conventions
		if (ref($obj->{_annotation_data}{standardised_note}) eq 'HASH'
				&& ($obj->{_annotation_data}{standardised_note}{surname} =~ /H[^ ]* M[^ ]* The King/i
				|| $obj->{_annotation_data}{standardised_note}{first} =~ /H[^ ]* M[^ ]* The King/i
				|| $obj->{_annotation_data}{standardised_note}{first} =~ /King George V/i
				|| $obj->{_annotation_data}{standardised_note}{surname} =~ /the king/i
				|| ($obj->{_annotation_data}{standardised_note}{surname} =~ /^george$/i
					&& $obj->{_annotation_data}{standardised_note}{first} =~ /^king$/i)
				)) {
			$logger->debug("Found a reference to the King",Dumper $obj->{_annotation_data}{standardised_note});
			$obj->{_annotation_data}{standardised_note}{rank} = 'other';
			$obj->{_annotation_data}{standardised_note}{first} = 'George';
			$obj->{_annotation_data}{standardised_note}{surname} = 'H M The King';
		}
		
		# The following block loops through some data-fixing processes to improve the chances of consensus by removing unnecessary or 
		# accidental superfluous punctuation, standardising the representation of persons' initials,etc.
		my $data_has_been_modified = 0;
		do {
			$data_has_been_modified = 0;
			# only free text fields need their punctuation standardised (removal of multiple spaces,
			# question marks, etc)
			if ($_annotation->{type} eq "person" || $_annotation->{type} eq "place" || $_annotation->{type} eq "unit" || $_annotation->{type} eq "gridRef") {
				$data_has_been_modified = $obj->_standardise_punctuation(); # fix spaces and strip question marks
				# for places, create a LatLong field because by the time we establish the consensus annotations, the lattitudes get
				# dumped in one pile and the longitudes in another. They need to be analysed together.
				if ($_annotation->{type} eq "place") {
					if ($_annotation->{note}{lat} ne '') {
						$obj->{_annotation_data}{standardised_note}{latlong} = $_annotation->{note}{lat}.",".$_annotation->{note}{long};
					}
					else {
						$obj->{_annotation_data}{standardised_note}{latlong} = '';
					}
				}
			}
			else {
				if (!defined $valid_annotation_types->{$obj->{_annotation_data}{type}}) {
					$logger->error("We have an unhandled annotation type: ", $obj->{_annotation_data}{type});
				}
			}
			if ($obj->{_annotation_data}{type} ne 'doctype') {
				$data_has_been_modified = $obj->_fix_known_errors();
				if ($data_has_been_modified) {
					undef;
				}
			}
		} until ($data_has_been_modified == 0);
#		if ($obj->{_annotation_data}{type} eq "diaryDate" && $obj->{_annotation_data}{standardised_note} !~ /^\d{1,2} [a-z]{3} \d{4}$/i) {
#			undef;
#		}
		return $obj;
	}
	else {
		$obj->DESTROY();
		return;
	}
}

sub get_type {
	my ($self) = @_;
	if (!defined $self->{_annotation_data}{type}) {
		die "Tag found without a type";
	}
	return $self->{_annotation_data}{type};
}

sub get_field {
	my ($self,$field) = @_;
	if (!defined $self->{_annotation_data}{standardised_note}{$field}) {
		return;
	}
	return $self->{_annotation_data}{standardised_note}{$field};
}

sub get_classification {
	my ($self) = @_;
	return $self->{_classification};
}

sub get_coordinates {
	my ($self) = @_;
	return $self->{_annotation_data}{coords};
}

sub get_id {
	my ($self) = @_;
	return $self->{_annotation_data}{id};
}

sub get_string_value {
	my ($self) = @_;
	my $string_value;
	if ($self->{_annotation_data}{type} eq 'place') {
		$string_value = $self->{_annotation_data}{standardised_note}{place};
	}
	elsif ($self->{_annotation_data}{type} eq 'person') {
		foreach my $key (keys %{$self->{_annotation_data}{standardised_note}}) {
			if (ref($self->{_annotation_data}{standardised_note}{$key}) eq 'ARRAY') {
				if ($key eq 'rank') {
					my $rank_preference_order = ['Second Lieutenant','Lieutenant','Quarter Master Sergeant','Company Quarter Master Sergeant','Bombardier','','other'];
					my $preferred_rank_found = 0;
					foreach my $preferred_rank (@$rank_preference_order) {
						foreach my $disputed_rank (@{$self->{_annotation_data}{standardised_note}{rank}}) {
							if ($preferred_rank eq $disputed_rank) {
								$self->{_annotation_data}{standardised_note}{rank} = $preferred_rank;
								$preferred_rank_found = 1;
								last;
							}
						}
						last if $preferred_rank_found;
					}
					if (!$preferred_rank_found) {
						my $rank_string;
						foreach my $disputed_rank (@{$self->{_annotation_data}{standardised_note}{rank}}) {
							$rank_string .= $disputed_rank."|";
						}
						$rank_string =~ s/\|$//;
						$self->{_annotation_data}{standardised_note}{rank} = $rank_string;
					}
				}
				elsif ($key eq 'reason') {
					my $reason_preference_order = ['departed_posted','joined','returned_hospital','returned_leave','promotion','casualty_kia','other','author'];
					my $preferred_reason_found = 0;
					foreach my $preferred_reason (@$reason_preference_order) {
						foreach my $disputed_reason (@{$self->{_annotation_data}{standardised_note}{reason}}) {
							if ($preferred_reason eq $disputed_reason) {
								$self->{_annotation_data}{standardised_note}{reason} = $preferred_reason;
								$preferred_reason_found = 1;
								last;
							}
						}
						last if $preferred_reason_found;
					}
				}
				else {
					$self->{_annotation_data}{standardised_note}{$key} = '';
					undef;
				}
			}
		}
		if ($self->{_annotation_data}{standardised_note}{rank} ne '') {
			$string_value = $self->{_annotation_data}{standardised_note}{rank};
		}
		if ($self->{_annotation_data}{standardised_note}{first} ne '') {
			if ($string_value ne '') {
				$string_value .= ' ';
			}
			$string_value .= $self->{_annotation_data}{standardised_note}{first};
		}
		if ($self->{_annotation_data}{standardised_note}{surname} ne '') {
			if ($string_value ne '') {
				$string_value .= ' ';
			}
			$string_value .= $self->{_annotation_data}{standardised_note}{surname};
		}
		if ($self->{_annotation_data}{standardised_note}{reason} ne '') {
			if ($string_value ne '') {
				$string_value .= ' ';
			}
			$string_value .= "(".$self->{_annotation_data}{standardised_note}{reason}.")";
		}
	}
	elsif ($self->{_annotation_data}{type} eq 'reference') {
		$string_value = $self->{_annotation_data}{standardised_note}{reference};
	}
	elsif ($self->{_annotation_data}{type} eq 'casualties') {
		$string_value = "died: $self->{_annotation_data}{standardised_note}{died}; killed: $self->{_annotation_data}{standardised_note}{killed}; missing: $self->{_annotation_data}{standardised_note}{missing}; prisoner: $self->{_annotation_data}{standardised_note}{prisoner}; sick: $self->{_annotation_data}{standardised_note}{sick}; wounded: $self->{_annotation_data}{standardised_note}{wounded}";
	}
	elsif ($self->{_annotation_data}{type} eq 'strength') {
		$string_value = "officer: $self->{_annotation_data}{standardised_note}{officer}; nco: $self->{_annotation_data}{standardised_note}{nco}; other: $self->{_annotation_data}{standardised_note}{other}";
	}
	elsif ($self->{_annotation_data}{type} eq 'unit') {
		$string_value = $self->{_annotation_data}{standardised_note}{name};
	}
	elsif ($self->{_annotation_data}{type} eq 'mapRef') {
		$string_value = $self->{_annotation_data}{standardised_note}{sheet};
	}
	elsif ($self->{_annotation_data}{type} eq 'gridRef') {
		$string_value = $self->{_annotation_data}{standardised_note}{gridref_a}.'_'.$self->{_annotation_data}{standardised_note}{gridref_b}.'_'.$self->{_annotation_data}{standardised_note}{gridref_c}.'_'.$self->{_annotation_data}{standardised_note}{gridref_d}.'_'.$self->{_annotation_data}{standardised_note}{gridref_e};
	}
	elsif ($self->{_annotation_data}{type} eq 'diaryDate'
			|| $self->{_annotation_data}{type} eq 'activity'
			|| $self->{_annotation_data}{type} eq 'time'
			|| $self->{_annotation_data}{type} eq 'domestic'
			|| $self->{_annotation_data}{type} eq 'weather'
			|| $self->{_annotation_data}{type} eq 'date'
			|| $self->{_annotation_data}{type} eq 'title'
			|| $self->{_annotation_data}{type} eq 'orders'
			|| $self->{_annotation_data}{type} eq 'signals'
			|| $self->{_annotation_data}{type} eq 'doctype') {
		$string_value = $self->{_annotation_data}{standardised_note};
	}
	else {
		Carp::carp("get_string_value() handler for type '".$self->{_annotation_data}{type}."' is not implemented");
	}
	return $string_value;
}

sub get_note {
	my ($self) = @_;
	return $self->{_annotation_data}{standardised_note};
}

sub set_note {
	my ($self,$note) = @_;
	$self->{_annotation_data}{standardised_note} = $note;
	return $note;
}

sub is_identical_to {
	my ($self,$other_annotation) = @_;
	# return true if the contents of the two annotations are identical after checking:
	# type, note (ignore coordinates and any other fields)
	if ($self->{_annotation_data}{type} eq $other_annotation->{_annotation_data}{type}) {
		if (ref($self->{_annotation_data}{note}) eq ref($other_annotation->{_annotation_data}{note})) {
			if (ref($self->{_annotation_data}{note}) eq 'HASH') {
				foreach my $key (keys %{$self->{_annotation_data}{note}}) {
					if ($self->{_annotation_data}{note}{$key} ne $other_annotation->{_annotation_data}{note}{$key}) {
						return 0;
					}
				}
			}
			else {
				if ($self->{_annotation_data}{note} ne $other_annotation->{_annotation_data}{note}) {
					return 0;
				}
			}
		}
		else {
			return 0;
		}
	}
	else {
		return 0;
	}
	return 1;
}

sub _standardise_punctuation {
	# strip out question marks that users have entered to indicate uncertainty (they don't help in finding consensus)
	# strip out multiple consecutive spaces
	# strip out leading spaces and trailing spaces
	my ($self) = @_;
	$logger->trace("OWD::Annotation->_standardise_punctuation() called");
	my $standardised_note;
	my $note_has_been_modified = 0;
	if (ref($self->{_annotation_data}{standardised_note}) eq "HASH") {
		foreach my $note_key (keys %{$self->{_annotation_data}{standardised_note}}) {
			my $original_value = $self->{_annotation_data}{note}{$note_key};
			my $type_and_key = $self->{_annotation_data}{type}.":".$note_key;
			if ($free_text_fields->{$type_and_key}) {
				my $standardised_field = $self->{_annotation_data}{standardised_note}{$note_key};
				if (($standardised_field =~ /\bking/i
						&& $standardised_field ne 'H M The King')) {
					$logger->debug("Possible mention of the King: $standardised_field");
				}
				if ($standardised_field =~ /\(?\?\)?/) {
					$standardised_field =~ s/\(?\?+\)?//g;
				}
				if ($standardised_field =~ m/ {2,}/) {
					$standardised_field =~ s/ {2,}/ /g;;
				}
				if ($standardised_field =~ m/\bSt\.? ?/) {
					if ($standardised_field =~ /St\.? Leonards/) {
						$standardised_field =~ s/\bSt.? /St /g;;
					}
					else {
						$standardised_field =~ s/\bSt.? /Saint /g;;
					}
				}
				if ($standardised_field =~ m/\bMt\.? ?/) {
					$standardised_field =~ s/\bMt.? /Mont /g;;
				}
				if ($type_and_key eq 'person:unit' && $standardised_field ne '') {
					my $field_is_unabbreviated = 0;
					do {
						my $unabbreviated_standardised_field = _unabbreviate_unit_name($standardised_field);
						if ($unabbreviated_standardised_field eq $standardised_field) {
							$field_is_unabbreviated = 1;
						}
						else {
							$standardised_field = $unabbreviated_standardised_field;
						}
					} while (!$field_is_unabbreviated);
					
				}
				if ( $type_and_key eq 'person:surname'
						 || $type_and_key eq 'place:place'
						 || $type_and_key eq 'person:unit') {
					if ($standardised_field =~ /([ \-])/) {
						my $delimiter = $1;
						my @tokens = split /$delimiter/,$standardised_field;
						my @new_tokens;
						foreach my $token (@tokens) {
							if ($token =~ m/\b[lL]'([a-z])/i) {
								my $sub = uc($1);
								$token =~ s/\b[lL]'[a-z]/l'$sub/i;
							}
							elsif ($token =~ m/\bles?\b/i
									|| $token =~ m/\bdes?\b/i
									|| $token =~ m/\bdu\b/i
									|| $token =~ m/\bla\b/i
									|| $token =~ m/^[lxvi]+$/i) {
								# do nothing.
							}
							elsif ($token !~ m/^[a-z]+$/i) {
								# do nothing
								undef;
							}
							else {
								$token = ucfirst(lc($token)) if $token =~ /^[a-z]/i;
							}
							push @new_tokens, $token;
						}
						$standardised_field = join $delimiter, @new_tokens;
#						print "Spaces/hyphens: $standardised_field\n";
					}
				}
				if ($standardised_field =~ /\b[A-Z]{2,}/ && $type_and_key ne 'person:unit') {
#					print "Multiple caps: $standardised_field\n";
					$standardised_field = ucfirst(lc($standardised_field));
				}
				if ($self->{_annotation_data}{type} eq 'gridRef') {
					$standardised_field = uc($standardised_field);
				}
				if ($standardised_field =~ /\b(?<!')([a-z]+)\b/ 
						&& $1 !~ /\ble\b/ && $1 !~ /\bl\b/) {
#					print "No caps: $standardised_field\n";
					if ($self->{_annotation_data}{type} eq 'person') {
						undef;
					}
					$standardised_field = ucfirst(lc($standardised_field)) if ($standardised_field =~ /^[a-z]/);
				}
				$standardised_field =~ s/^\s+//;
				$standardised_field =~ s/\s+$//;
				
				$standardised_note->{$note_key} = $standardised_field;
			}
			else {
				$standardised_note->{$note_key} = $self->{_annotation_data}{standardised_note}{$note_key};
			}
			if ($standardised_note->{$note_key} ne $original_value) {
				$note_has_been_modified = 1;
				#print "$original_value -> $standardised_note->{$note_key}\n" if $type_and_key ne 'person:first';
				#print "$type_and_key: $original_value\n" if ($type_and_key ne 'place:placeOption' && $type_and_key !~ /ui-id-\d+/ && $type_and_key ne 'place:country');
			}
		}
	}
	else {
		$standardised_note = $self->{_annotation_data}{standardised_note};
	}
	$self->{_annotation_data}{standardised_note} = $standardised_note;
	return $note_has_been_modified;
}

sub _fix_known_errors {
	my ($self) = @_;
	$logger->trace("_fix_known_errors called");
	my $annotation = $self->{_annotation_data};
	my $original_note;
	if (ref($annotation->{standardised_note}) eq 'HASH') {
		foreach my $key (%{$annotation->{standardised_note}}) {
			$original_note->{$key} = $annotation->{standardised_note}{$key};
		}
	}
	else {
		$original_note = $annotation->{standardised_note};
	}
	if ($annotation->{type} eq "diaryDate") {
		# a bug was introduced in the app where sometimes the date format was not dd mmm yyyy
		# but only for September, and only sometimes!
		if ($annotation->{standardised_note} =~ /September/) {
			$annotation->{standardised_note} =~ s/September/Sep/;
			my $error = {
				'type'		=> 'annotation_error; september_date_bug',
				'detail'	=> $annotation->{id}.' uses \'September\' for month instead of \'Sep\'. auto-fixed.',
			};
			$self->data_error($error);
		}
		# some users, when they weren't sure of a date, entered "191" as in "the first three
		# digits of the year are 191" which is true of all diaryDates in WWI, but not helpful
		# for establishing a consensus on dates.
		if ($annotation->{standardised_note} =~ /^((\d{1,2}) ([a-z]{3})) (\d{3})$/i) {
			$annotation->{standardised_note} = $1;
			my $error = {
				'type'		=> 'annotation_error; incomplete_year_user_error',
				'detail'	=> $annotation->{id}.' has a three digit year: \''.$2.'\'. year removed.',
			};
		}
		# check here that the day of the month is valid for the month (eg not the 30th Feb or 31st April)
		$annotation->{standardised_note} =~ /^((\d{1,2}) ([a-z]{3}))( \d{4})?$/i;
		my ($annotation_day,$annotation_month) = ($2,$3);
		if ($annotation_day > $days_in_month[$month{$annotation_month}]) {
			my $error = {
				'type'		=> 'annotation_error; day_of_month_too_high',
				'detail'	=> $annotation->{id}.' has an invalid date: \''.$annotation->{standardised_note}.'\'',
			};
			return 0;
		}
	}
	elsif ($annotation->{type} eq "unit") {
		$annotation->{standardised_note}{name} = _unabbreviate_unit_name($annotation->{standardised_note}{name});
	}
	elsif ($annotation->{type} eq "person") { # the person field also includes a unit field
		if ($annotation->{standardised_note}{unit} ne '') {
			$annotation->{standardised_note}{unit} = _unabbreviate_unit_name($annotation->{standardised_note}{unit});
		}					
		# tidy names by: enforcing rules:
		# - initials in upper case, single spaced, no full stops, and remove titles (Sir, Hon, etc)
		$annotation->{standardised_note}{first} = _tidy_user_entry($annotation->{standardised_note}{first}, "person:first");
		$annotation->{standardised_note}{surname} = _tidy_user_entry($annotation->{standardised_note}{surname}, "person:surname");
	}
	elsif ($annotation->{type} eq "place") {
		# if places are past 10 (x axis) assume that they aren't the unit location
#		if ($annotation->{coords}[0] > 10) {
#			$annotation->{standardised_note}{probable_location} = "false";
#		}
#		else {
#			$annotation->{standardised_note}{probable_location} = 'true';
#		}
		foreach my $country (@countries) {
			if ($annotation->{standardised_note}{place} =~ /, *$country/i) {
				$annotation->{standardised_note}{place} =~ s/, *$country//i;
				$annotation->{standardised_note}{country} = $country;
				last;
			}
		}
		foreach my $field (keys %{$annotation->{standardised_note}}) {
			if ($field =~ /(ui-id-\d+)/) {
				$annotation->{standardised_note}{placeOption} = $annotation->{standardised_note}{$1};
				delete $annotation->{standardised_note}{$1}; 
			}
		}
		foreach my $note_field (keys %{$annotation->{standardised_note}}) {
			if (!defined($valid_note_fields->{place}{$note_field})) {
				undef;
			}
		}
	}
	my $note_has_been_changed = 0;
	if (ref($annotation->{standardised_note}) eq 'HASH') {
		foreach my $key (%{$annotation->{standardised_note}}) {
			$note_has_been_changed=1 if $annotation->{standardised_note}{$key} ne $original_note->{$key};
		}
	}
	else {
		$note_has_been_changed=1 if $annotation->{standardised_note} ne $original_note;
	}
	return $note_has_been_changed;
}

sub _data_consistent {
	# This method is called during the creation of the annotation object, a bare minimal check that the data for the particular
	# annotation is usable at all.
	# TODO: Rather than dropping an annotation with insufficient information (eg a diaryDate that's not in
	# ^\d{1,2} [a-z]{3} \d{4}$/ format) maybe we could remove anything inconsistent and save the correct but
	# incomplete information?
	my ($self) = @_;
	$logger->trace("OWD::Annotation->_data_consistent() called");
	# first check if a 'confirmed' db exists, which can store the results of QA work and list annotations that can be dropped/deleted
	# after failing QA. If the DB doesn't exist, all annotations are treated equally.
#	if (ref($self->{_classification}->get_page()->get_diary()->get_processor()->get_confirmed_db()) eq 'MongoDB::Database') {
#		print "Querying confirmed_db for overruling annotation\n" if $debug > 2;
#		my $coll_delete = $self->{_classification}->get_page()->get_diary()->get_processor()->get_delete_collection();
#		my $obj_to_delete = $coll_delete->find_one({'annotation_id' => $self->{_annotation_data}{id}});
#		print "Query Complete\n" if $debug > 2;
#		if (ref($obj_to_delete) eq 'HASH') {
#			return 0;
#		}
#	}
	
	my $annotation = $self->{_annotation_data};
	if (defined $annotation->{type}) {
		# TODO: lots of types are missing from this section. Could reliability be improved by adding checks here for the missing types?
		# This block validates the entries according to their data types
		if ($annotation->{type} eq 'doctype' && !defined($valid_doctypes->{$annotation->{note}})) {
			my $error = {
				'type'		=> 'annotation_error; unexpected_value',
				'detail'	=> 'doctype \''.$annotation->{note}.'\' not recognised',
			};
			$logger->warn("annotation doctype field has invalid value: '",$annotation->{note},"'");
			$self->data_error($error);
			return 0;
		}
		elsif ($annotation->{type} eq "person") {
			# person type without note hash
			if (ref $annotation->{note} ne "HASH") {
				my $error = {
					'type'		=> 'annotation_error; unexpected_note_type',
					'detail'	=> 'person type with no note hash',
				};
				$logger->warn("annotation person field is not a hash, as expected",ref($annotation->{note}));
				$self->data_error($error);
				return 0;
			}
		}
		elsif ($annotation->{type} eq "diaryDate") {
			# diary date without actual date
			if ($annotation->{note} eq '') {
				my $error = {
					'type'		=> 'annotation_error; missing_mandatory_value',
					'detail'	=> 'diaryDate has no note field',
				};
				$logger->trace("annotation diaryDate field by ", $self->get_classification()->get_classification_user(), " on page ",$self->get_classification()->get_page()->get_page_num()," (",$self->get_classification()->get_page()->get_diary()->get_zooniverse_id(),"/",$self->get_classification()->get_page()->get_zooniverse_id(),") does not have a value");
				$self->data_error($error);
				return 0;
			}
			elsif ($annotation->{note} !~ /^\d{1,2} [a-z]{3,9} \d{4}$/i) {
				my $error = {
					'type'		=> 'annotation_error; invalid diaryDate format',
					'detail'	=> '\''.$annotation->{note}.'\' doesn\'t match expected date format \'dd mmmm yyyy\'',
				};
				$logger->debug("annotation diaryDate value doesn't match expected date format: '",$annotation->{note},"'");
				$self->data_error($error);
				return 0;
			}
		}
		elsif ($annotation->{type} eq "date") {
			# date without actual date
			if ($annotation->{note} eq '') {
				my $error = {
					'type'		=> 'annotation_error; missing_mandatory_value',
					'detail'	=> 'date has no note field',
				};
				$logger->trace("annotation date field by ", $self->get_classification()->get_classification_user(), " on page ",$self->get_classification()->get_page()->get_page_num()," (",$self->get_classification()->get_page()->get_diary()->get_zooniverse_id(),"/",$self->get_classification()->get_page()->get_zooniverse_id(),") does not have a value");
				$self->data_error($error);
				return 0;
			}
			elsif ($annotation->{note} !~ /^\d{1,2} [a-z]{3} \d{4}$/i) {
				my $error = {
					'type'		=> 'annotation_error; invalid date format',
					'detail'	=> '\''.$annotation->{note}.'\' doesn\'t match expected date format \'dd mmmm yyyy\'',
				};
				$self->data_error($error);
				return 0;
			}
		}
		else {
			if (!defined $annotation->{note} || $annotation->{note} eq '') {
				my $error = {
					'type'		=> 'annotation_error; blank_or_no_note',
					'detail'	=> '\''.$annotation->{id}.'\' (type \''.$annotation->{type}.'\' has no note value',
				};
				$logger->trace("annotation type ",$self->get_type()," by ", $self->get_classification()->get_classification_user(), " on page ",$self->get_classification()->get_page()->get_page_num()," (",$self->get_classification()->get_page()->get_diary()->get_zooniverse_id(),"/",$self->get_classification()->get_page()->get_zooniverse_id(),") does not have a note value");
				$self->data_error($error);
				return 0;
			}
		}
	}
	else {
		# is there any circumstance where the annotation doesn't have a type?
		my $error = {
			'type'		=> 'annotation_error; no type field',
			'detail'	=> 'annotation without a type',
		};
		$logger->warn("annotation doesn't have a type");
		$self->data_error($error);
		return 0;
	}
	return 1;
}

sub _tidy_user_entry {
	# the purpose of this sub is to remove and standardise punctuation for easier matching
	my ($string, $field_name) = @_;
	if ($string ne "") {
		my $original_string = $string;
		if ($field_name eq "person:first") {
			$string =~ s/\. ?/ /g;	# remove full stops from dotted initials
			$string =~ s/, ?/ /g;	# remove commas
			if ($string =~ /'/ && $string !~ /d'arcy/i) {
				print "Apostrophe found in first name: '$string'\nPress Enter to continue\n";
				#<STDIN>; # DEBUG DELETE
				#$string =~ s/'/ /g;	# remove apostrophes
			}
			$string =~ s/^\s+//;	# remove leading spaces
			if ($string =~ /\bLORD\b/) {
				$string =~ s/LORD/Lord/; # a later substitution converts 2-4 upper case charaters into space delimited initials
			}
			if ($string =~ /^[A-Z]{2,4}$/) {
				$string =~ s/([A-Z])/$1 /g; # convert "ABC" format initials to "A B C " format
				$string = _tidy_user_entry($string, $field_name) if ($string ne $original_string);
			}
			if ($string =~ /(?:\b[a-z]\b ?)+$/) {
				my @substring = split / /,$string;
				my $replacement_string = '';
				foreach my $substring (@substring) {
					if ($substring =~ /^[a-z]$/) {
						$replacement_string .= uc($substring)." ";
					}
					else {
						$replacement_string .= $substring." ";
					}
				}
				$string = $replacement_string;
#				$string = uc $string; # uppercase all initials
				$string = _tidy_user_entry($string, $field_name) if ($string ne $original_string);
			}
			if ($string =~ /^(?:\b[a-z]\b ?)+$/) {
				$string = uc $string; # uppercase all initials
				$string = _tidy_user_entry($string, $field_name) if ($string ne $original_string);
			}
			if ($string =~ /\bSir /) {
				$string =~ s/\bSir //; # remove titles. Consider creating a separate field for stripped titles
				$string = _tidy_user_entry($string, $field_name) if ($string ne $original_string);
			}
			if ($string =~ /(The )?\bHon\.? /) {
				$string =~ s/(The )?\bHon\.? //; # remove titles. Consider creating a separate field for stripped titles
				$string = _tidy_user_entry($string, $field_name) if ($string ne $original_string);
			}
			$string =~ s/\s+$//;
			return $string;
		}
		elsif ($field_name eq "person:surname") {
			if ($string =~ /illegible/i) {
				return "";
			}
			$string =~ s/^\s+//;
			$string =~ s/[\s\.,]+$//;
			# the following block of code attempts to strip out common suffixes from the surname
			# field.  The suffixes are not really part of the name, and often result in
			# disputed annotations because some volunteers include them when others don't
			# In order to be processed, a name must not be a single string of all caps, and
			# should include a space followed by a sequence of 2-12 letters or punctuation
			# if the string meets these criteria, it is checked against known suffixes
			if ($string !~ /^[A-Z]+$/ && $string =~ /\w+(?:, *| +)?\b([\w\. ]{2,12})\b/) {
				if ($string =~ /($military_suffixes_regex)[,\. ]*$/i) {
					my $new_string = $string;
					$new_string =~ s/(?:$military_suffixes_regex)[,\. ]*$//gi;
					# print "'$string' -> '$new_string'\n";
					# reject new_string if it ends in \bstopWord
					#   eg to
					if ($new_string !~ /\bto *$/) {
						$string = _tidy_user_entry($new_string, $field_name);
					}
				}
			}
			if ($string =~ /\bRAMC\b/) {
				$string =~ s/\bRAMC\b//;
				$string = _tidy_user_entry($string, $field_name);
			}
			if ($string =~ /^[a-z]{2,}$/) {
				$string = ucfirst $string;
				$string = _tidy_user_entry($string, $field_name);
			}
			if ($string =~ /^[A-Z]{2,}$/) {
				$string = ucfirst(lc $string);
				$string = _tidy_user_entry($string, $field_name);
			}
			if ($string =~ m/ +-./ || $string =~ m/.- +/) {
				$string =~ s/ *- */-/;
			}
			if ($string ne $original_string) {
				#print "'$original_string' changed to '$string'\n";
			}
			return $string;
		}
		else {
			return $string;
		}
	}
}

sub _unabbreviate_unit_name {
	my ($unit_name) = @_;
	print "OWD::Annotation->_unabbreviate_unit_name called\n" if $debug > 2;
	my $original_unit_name = $unit_name;
	if ($unit_name =~ m|\bA\.D\.V\.S\.?\b|i) {
		$unit_name =~ s|\bA\.D\.V\.S\.?\b|Assistant Director Veterinary Service|i;
	}
	if ($unit_name =~ m|\bAmmn\b|i) {
		$unit_name =~ s|\bAmmn\b|Ammunition|i;
	}
	if ($unit_name =~ m|\bbde\.|i) {
		$unit_name =~ s|\bbde\.|Brigade|i;
	}
	if ($unit_name =~ m|\bbde\b|i) {
		$unit_name =~ s|\bbde\b|Brigade|i;
	}
	if ($unit_name =~ m|\bbr[ai]gai?de\b|i) {
		$unit_name =~ s|\bbr[ai]gai?de\b|Brigade|i;
	}
	if ($unit_name =~ m|\bbr(ig)?\.|i) {
		$unit_name =~ s|\bbr(ig)?\.|Brigade|i;
	}
	if ($unit_name =~ m|\bbr(ig)?\b|i) {
		$unit_name =~ s|\bbr(ig)?\b|Brigade|i;
	}
	if ($unit_name =~ m|\bamm? +coln?\b|i) {
		$unit_name =~ s|\bamm? +coln?\b|Ammunition Column|;
	}
	if ($unit_name =~ m|\bbatt\b.*(r[fh]a\|artillery)|i) {
		$unit_name =~ s|\bbatt[\.\b]|Battery|i;
	}
	if ($unit_name =~ m|\bbatt\b.*(r[fh]a\|artillery)|i) {
		$unit_name =~ s|\bbatt\b|Battery|i;
	}
	if ($unit_name =~ m|\bbatt\b|i) {
		$unit_name =~ s|\bbatt\b|Battalion|i;
	}
	if ($unit_name =~ m|\bbattn\b|i) {
		$unit_name =~ s|\bbattn\b|Battalion|i;
	}
	if ($unit_name =~ m|\bbattery\b|i) {
		$unit_name =~ s|\bbattery\b|Battery|i;
	}
	if ($unit_name =~ m|\bbty\b|i) {
		$unit_name =~ s|\bbty\b|Battery|i;
	}
	if ($unit_name =~ m|\bcav\.|i) {
		$unit_name =~ s|\bcav\.|Cavalry|i;
	}
	if ($unit_name =~ m|\bcav\b|i) {
		$unit_name =~ s|\bcav\b|Cavalry|i;
	}
	if ($unit_name =~ m|\bcavalry\b|i) {
		$unit_name =~ s|\bcavalry\b|Cavalry|i;
	}
	if ($unit_name =~ m|\bdivn?\b|i) {
		$unit_name =~ s|\bdivn?\b|Division|i;
	}
	if ($unit_name =~ m|\bdiviion?\b|i) {
		$unit_name =~ s|\bdiviion?\b|Division|i;
	}
	if ($unit_name =~ m|\bd[ie]vision\b|i) {
		$unit_name =~ s|\bd[ie]vision\b|Division|i;
	}
	if ($unit_name =~ m|\bd\.g\.[\b.*]?$|i) {
		$unit_name =~ s|\bd\.g\.|Dragoon Guards|i;
	}
	if ($unit_name =~ m|\bd[\.(ragoon)]?\s?gds\.?[\b.*]?$|i) {
		$unit_name =~ s|\bd[\.(ragoon)]?\s?gds\.?|Dragoon Guards|i;
	}
	if ($unit_name =~ m|\bhussars\b|i) {
		$unit_name =~ s|\bhussars\b|Hussars|i;
	}
	if ($unit_name =~ m|\bregt\b|i) {
		$unit_name =~ s|\bregt\b|Regiment|i;
	}
	if ($unit_name =~ m|\br\.e\.[\b.*]?$|i) {
		$unit_name =~ s|\br\.e\.|Royal Engineers|i;
	}
	if ($unit_name =~ m|\bregiment\b|i) {
		$unit_name =~ s|\bregiment\b|Regiment|i;
	}
	if ($unit_name =~ m/\d+(st|nd|rd|th)\.?/i) {
		$unit_name =~ s/(\d+)(?:st|nd|rd|th)\.?/$1/i
	}
	if ($unit_name =~ m/\br\.?f\.?a\.?\b/i) {
		$unit_name =~ s/\br\.?f\.?a\.?\b/Royal Field Artillery/i
	}
	if ($unit_name =~ m/\brha\b/i) {
		$unit_name =~ s/\brha\b/Royal Horse Artillery/i
	}
	if ($unit_name =~ m/\bRoyal Horse Artillery\b/i) {
		$unit_name =~ s/\bRoyal Horse Artillery\b/Royal Horse Artillery/i
	}
	if ($unit_name =~ m/\br\.?i\.?r\.?\b/i) {
		$unit_name =~ s/\br\.?i\.?r\.?\b/Royal Irish Regiment/i
	}
	if ($unit_name =~ m/["'][A-Z]/i) {
		$unit_name =~ s/["']//g;
	}

	if ($unit_name ne $original_unit_name) {
		#print "Unit name: '$original_unit_name' changed to '$unit_name'\n";
	}
	print "_unabbreviate_unit_name complete\n" if $debug > 2;
	return $unit_name;
}

sub ignore_place_georeference {
	# There was a bug in the early georeferencing code that means the earlier georeferences
	# were often of the wrong placename. Use the date of the annotation to determine whether
	# to ignore any georeference information present.
	my ($self) = @_;
	if ($self->{_cluster}->get_first_annotation()->{_classification}{_classification_data}{created_at}->epoch() < 1393632000) {
		return 0;
	}
	else {
		return 1;
	}
}

sub data_error {
	my ($self,$error_hash) = @_;
	if (!defined $error_hash->{annotation}) {
		$error_hash->{annotation} = {
			'id'		=> $self->get_id(),
		};
	}
	$self->{_classification}->data_error($error_hash);
}

sub DESTROY {
	my ($self) = @_;
	$self->{_classification} = undef;
}

1;