package OWD::Classification;
use strict;
use Data::Dumper;
use OWD::Annotation;
use Log::Log4perl;

my $logger = Log::Log4perl->get_logger();

my $debug = 1;

sub new {
	$logger->trace("OWD::Classification::new() called");
	my ($class, $_page, $_classification) = @_;
	my @_annotations;
	my $classification_obj = bless {}, $class;

	if (!defined $_classification->{user_name}) { # Ensure every classification has a user_name
		if (defined $_classification->{user_ip}) {
			$_classification->{user_name} = "<anonymous>-$_classification->{user_ip}";
		}
		else {
			$_classification->{user_name} = $_classification->{_id};
		}
	}
	$classification_obj->{_page} = $_page;
	$classification_obj->{_classification_data} = $_classification;
	$classification_obj->{_num_annotations} = 0;
	my $coord_check;
	foreach my $annotation (@{$_classification->{annotations}}) {
		# if the annotation type is "document", create an OWD::Annotation object out of it
		# by rearranging it into a more Annotation-like structure
		if (defined $annotation->{document}) {
			$annotation->{type} = 'doctype';
			$annotation->{note} = $annotation->{document};
			$annotation->{coords} = [0,0];
			delete $annotation->{document};
		}
		$annotation->{id} = $_classification->{subjects}[0]{zooniverse_id}.'_'.$_classification->{user_name}.'_'.$annotation->{coords}[0].'_'.$annotation->{coords}[1];

		# for non-coordinate annotations, push them into the classification metadata
		# as they aren't really volunteer defined anyway
		if (defined $annotation->{finished_at}) {
			$_classification->{finished_at} = $annotation->{finished_at};
		}
		elsif (defined $annotation->{user_agent}) {
			$_classification->{user_agent} = $annotation->{user_agent};
		}
		else {
			my $coord_check_string = _coord_check_string($annotation->{coords}); # used to spot a bug where an annotation is sometimes listed twice
			$logger->trace("Processing a page annotation at $coord_check_string");
			# The OWD::Annotation constructor does some initial checks that the value for various annotation types is valid as well as doing other
			# tweaks to create a "standardised annotation" (with more chance of consensus) from the raw annotation.
			my $obj_annotation = OWD::Annotation->new($classification_obj,$annotation);
			# record the coordinates to enable duplicate checks.
			if (ref($obj_annotation) eq 'OWD::Annotation') {
				if (defined($coord_check->{$coord_check_string})) {
					# a user has managed to log two annotations in exactly the same place. This is likely
					# a bug and could result in a single user getting two "votes" on what entity is here.
					# Check if the annotations are identical, and if they are, drop and log.
					$logger->trace("duplicate annotation found in classification by ", $classification_obj->get_classification_user(), " on page ", $classification_obj->get_page()->get_page_num()," (",$classification_obj->get_page()->get_diary()->get_zooniverse_id(),"/",$classification_obj->get_page()->get_zooniverse_id());
					if ($obj_annotation->is_identical_to($coord_check->{$coord_check_string})) {
						my $error = {
							'type'		=> 'classification_error; duplicate_annotations',
							'detail'	=> $classification_obj->{_classification_data}{user_name}.'\'s classification contains duplicate annotations at $coord_check_string',
						};
						$classification_obj->data_error($error);
						$obj_annotation->DESTROY();
						next;
					}
					else {
						# the two annotations in the same place are actually different.
						# this appears to be another bug, where of the two annotations in the same
						# place, the first one in the array is an "echo" of a previous annotation
						# so far, the second annotation always looks to be the one to keep.
						# Get the @_annotations array element containing the earlier annotation,
						# DESTROY() it to remove the  circular reference, then splice it out of the array
						for (my $i=0; $i<@_annotations;$i++) {
							if (_coord_check_string($_annotations[$i]->{_annotation_data}{coords}) eq $coord_check_string) {
								$_annotations[$i]->DESTROY();
								splice(@_annotations,$i,1);
							}
						}
						my $error = {
							'type'		=> 'classification_error; two_annotations_at_same_coord',
							'detail'	=> $classification_obj->{_classification_data}{user_name}.'\'s classification contains two annotations at $coord_check_string',
						};
						$classification_obj->data_error($error);
					}
				}
				push @_annotations, $obj_annotation;
				$coord_check->{$coord_check_string} = $obj_annotation;
			}
			else {
				# Annotation object was not successfully created, most likely because of a data error
#				unless (($annotation->{type} eq "diaryDate" || $annotation->{type} eq "date" ) && !defined($annotation->{note})) {
#					print "Annotation $annotation->{id} rejected\n";
#					print Dumper $annotation;
#					undef;
#				}
				$logger->trace("Annotation creation failed");
			}
		}

		$classification_obj->{_num_annotations}++;
		$logger->trace("Annotation object created and added to classification");
	}
	$logger->trace("  Classification by $_classification->{user_name} ($_classification->{finished_at}): $classification_obj->{_num_annotations} annotations");	
	delete $_classification->{annotations}; # separate the individual annotations from the classification object
	my $sorted_annotations = [sort {$a->{_annotation_data}{id} cmp $b->{_annotation_data}{id}} @_annotations];
	$classification_obj->{_annotations} = $sorted_annotations;
	undef %$coord_check;
	return $classification_obj;
}

sub get_tag_type_counts {
	my ($self) = @_;
	my $tag_stats = {};
	foreach my $annotation (@{$self->{_annotations}}) {
		$tag_stats->{$annotation->get_type()}++;
	}
	return $tag_stats;
}

sub get_classification_user {
	my ($self) = @_;
	return $self->{_classification_data}{user_name};
}

sub get_page {
	my ($self) = @_;
	return $self->{_page};
}

sub data_error {
	my ($self, $error_hash) = @_;
	if (!defined $error_hash->{classification}) {
		$error_hash->{classification} = {
			'user_name'		=>  $self->get_classification_user(),
		};
	}
	$self->{_page}->data_error($error_hash);
}

sub compare_classifications {
	my ($self,$other) = @_;
	print "0: $self->{_classification_data}{finished_at}\n";
	print "1: $other->{_classification_data}{finished_at}\n";
	print "0: ",scalar(@{$self->{_annotations}}), " annotations\n";
	print "1: ",scalar(@{$other->{_annotations}}), " annotations\n";
	print "0:\n";
	print Dumper $self->get_tag_type_counts();
	print "1:\n";
	print Dumper $other->get_tag_type_counts();
}

sub get_annotations_count {
	my ($self) = @_;
	return scalar @{$self->{_annotations}};
}

sub get_mongo_id {
	my ($self) = @_;
	return $self->{_classification_data}{_id}{value};
}

sub get_updated_at {
	my ($self) = @_;
	return $self->{_classification_data}{updated_at};
}

sub get_doctype {
	my ($self) = @_;
	return $self->{_classification_data}{doctype};
}

sub get_annotations_by_type {
	my ($self) = @_;
	my $annotations_by_type = {};
	foreach my $annotation (@{$self->{_annotations}}) {
		push @{$annotations_by_type->{$annotation->get_type()}}, $annotation;
	}
	return $annotations_by_type;
	# ensure this reference is destroyed to prevent memory leak
}

sub _coord_check_string {
	my ($coords) = @_;
	return $coords->[0].'_'.$coords->[1];
}

sub DESTROY {
	my ($self) = @_;
	foreach my $annotation (@{$self->{_annotations}}) {
		if (ref($annotation) eq 'OWD::Annotation') {
			$annotation->DESTROY();
		}
		else {
			undef;
		}
	}
	$self->{_page} = undef;
}

=pod

=head1 NAME

OWD::Classification - a class representing a single user classification of a page, analagous to a document from the war_diary_classifications collection of the OWD Mongo database.

=head1 VERSION

v0.1

=head1 SYNOPSIS

use OWD::Classification;

my $classification = OWD::Classification->new(<OWD::Page>, $classification_document_ref);


=head1 DESCRIPTION

=head1 SUBROUTINES/METHODS

=head2 new

	OWD::Classification->new(<OWD::Page>, $classification_document_ref);
	
Creates a Classification object. Required parameters are the OWD::Page object to which the classification refers, and the classification hash returned by the find() Mongo command

The constructor doesn't load the data exactly as is, but does some QA checks to filter out known data issues.

=cut

1;