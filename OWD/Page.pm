package OWD::Page;
use strict;
use OWD::Classification;
use OWD::Cluster;
use Algorithm::ClusterPoints;
use Data::Dumper;
use Text::LevenshteinXS;
use Carp;
use DateTime::Format::Natural;
use Log::Log4perl;

my $logger = Log::Log4perl->get_logger();

$Data::Dumper::Maxdepth = 4;
my $debug = 1;
my $diaryDate_y_axis_skew = -2; # keep this in sync with the similar value in Cluster.pm

sub new {
	my ($class, $_diary, $_subject) = @_;
	$logger->trace("OWD::Page constructor called");
	return bless {
		'_page_data'	=> $_subject,
		'_diary'		=> $_diary,
	}, $class;
	# ^ destroy _diary circular ref when the page is destroyed
}

sub load_classifications {
	$logger->trace("OWD::Page::load_classifications() called");
	my ($self) = @_;
	my $page = $self->get_page_num();
	my $_classifications = [];
	$logger->trace("performing mongo query to fetch classifications for this page\ndb.war_diary_classifications.find({'subjects.zooniverse_id': ".$self->{_page_data}->{zooniverse_id}."})");
	my $cur_classifications = 
		$self->{_diary}->{_processor}->{coll_classifications}->find(
			{'subjects.zooniverse_id' => $self->{_page_data}->{zooniverse_id} }
		);
	$cur_classifications->fields({'annotations'=>1,'subjects'=>1,'updated_at'=>1,'user_ip'=>1,'user_name'=>1,'_id'=>1});
	$cur_classifications->sort({"_id" => 1});
	if ($cur_classifications->has_next) {
		$logger->trace("  Iterating through classifications cursor");
		while (my $classification = $cur_classifications->next) {
			push @$_classifications, OWD::Classification->new($self,$classification);
		}
		$logger->trace("  Completed iterating through classifications. ",scalar(@$_classifications)," classifications found");
		my $sorted_classifications = [sort {$a->{_classification_data}{user_name} cmp $b->{_classification_data}{user_name}} @$_classifications];
		$self->{_classifications} = $sorted_classifications;
		undef $cur_classifications;
		return 1;
	}
	else {
		return;
	}
}

sub load_hashtags {
	my ($self) = @_;
	my $_hashtags = {};
	my $cur_hashtags = 
		$self->{_diary}->{_processor}->get_hashtags_collection()->find(
			{'focus.name' => $self->{_page_data}->{zooniverse_id} }
		);
	if ($cur_hashtags->has_next) {
		while (my $entry = $cur_hashtags->next) {
			foreach my $comment (@{$entry->{comments}}) {
				while ($comment->{body} =~ /(#\w+)/g) {
					$_hashtags->{$1}++;
				}
			}
		}
		$self->{_hashtags} = $_hashtags;
		undef $cur_hashtags;
		return 1;
	}
	else {
		return;
	}
}

sub get_raw_tag_type_counts {
	my ($self) = @_;
	my $page_tag_counts = {};
	foreach my $classification (@{$self->{_classifications}}) {
		my $classification_tag_counts = $classification->get_tag_type_counts();
		while (my ($type,$count) = each %$classification_tag_counts) {
			$page_tag_counts->{$type} += $count;
		}
	}
	return $page_tag_counts;
}

sub strip_multiple_classifications_by_single_user {
	# More than 10,000 classifications are from users who have already classified a particular
	# page. This method checks for this problem and tries to ensure only the best classification
	# is preserved.
	my ($self) = @_;
	my %num_classifications_by;
	my $num_classifications_before_strip = $self->num_classifications();
	my $logging_db = $self->{_diary}{_processor}->get_logging_db();
	my $coll_log = $logging_db->get_collection('log');
	foreach my $classification (@{$self->{_classifications}}) {
		$num_classifications_by{$classification->get_classification_user()}++;
	}
	foreach my $user (keys %num_classifications_by) {
		my $value = $num_classifications_by{$user};
		if ($value > 1) {
			my $best_classification = "";
			#print "$user has multiple classifications for $self->{_page_data}{zooniverse_id}\n";
			$coll_log->insert_one({
				'diary'			=> {
					'group_id'		=> $self->{_diary}->get_zooniverse_id(),
					'docref'		=> $self->{_diary}->get_docref(),
					'iaid'			=> $self->{_diary}->get_iaid(),
				},
				'page'			=> {
					'subject_id'	=> $self->get_zooniverse_id(),
					'page_num'		=> $self->get_page_num(),
				},
				'type'				=> "multiple_classifications_of_page_by_single_user",
				'detail'			=> "$user has multiple classifications for $self->{_page_data}{zooniverse_id}",
			});
			my $classifications_by_user = $self->get_classifications_by($user);
			# iterate through classifications i and i+1. Select the best one
			my $classification_scores = {};
			foreach my $classification (@$classifications_by_user) {
				push @{$classification_scores->{$classification->get_annotations_count()}},
					{
						'id'			=> $classification->get_mongo_id(),
						'updated_at'	=> $classification->get_updated_at(),
					};
			}
			my $hi_score = (reverse sort keys %$classification_scores)[0];
			if (@{$classification_scores->{$hi_score}} == 1) {
				$best_classification = $classification_scores->{$hi_score}[0]{id};
			}
			else {
				my $latest_timestamp;
				foreach my $classification (@{$classification_scores->{$hi_score}}) {
					if (!defined $latest_timestamp || DateTime->compare($latest_timestamp,$classification->{updated_at}) < 0) {
						$latest_timestamp = $classification->{updated_at};
						$best_classification = $classification->{id};
					}
				}
			}
			my $replacement_classifications;
			for (my $i = 0; $i<@{$self->{_classifications}}; $i++) {
				if ($self->{_classifications}[$i]->get_classification_user() ne $user
					|| ($self->{_classifications}[$i]->get_classification_user() eq $user
						&& $self->{_classifications}[$i]->get_mongo_id eq $best_classification)) {
						push @$replacement_classifications, $self->{_classifications}[$i];
				}
				else {
					$self->{_classifications}[$i]->DESTROY();
				}
			} 
			$self->{_classifications} = $replacement_classifications;
		}
	}
	my $num_classifications_after_strip = $self->num_classifications();
	if ($num_classifications_before_strip > $num_classifications_after_strip) {
		my $diff = $num_classifications_before_strip - $num_classifications_after_strip;
		$coll_log->insert_one({
			'diary'			=> {
				'group_id'		=> $self->{_diary}->get_zooniverse_id(),
				'docref'		=> $self->{_diary}->get_docref(),
				'iaid'			=> $self->{_diary}->get_iaid(),
			},
			'page'			=> {
				'subject_id'	=> $self->get_zooniverse_id(),
				'page_num'		=> $self->get_page_num(),
			},
			'type'				=> "some_classifications_inadmissable",
			'detail'			=> "$diff / $num_classifications_before_strip",
		});
	}
}

sub get_classifications_by {
	my ($self, $username) = @_;
	my $classifications_by_user = [];
	foreach my $classification (@{$self->{_classifications}}) {
		if ($classification->get_classification_user() eq $username) {
			push @$classifications_by_user, $classification;
		}
	}
	return $classifications_by_user;
}

sub get_zooniverse_id {
	my ($self) = @_;
	return $self->{_page_data}{zooniverse_id};
}

sub get_page_num {
	my ($self) = @_;
	return $self->{_page_data}{metadata}{page_number};
}

sub get_diary {
	my ($self) = @_;
	return $self->{_diary};
}

sub get_hashtags {
	my ($self) = @_;
	return $self->{_hashtags};
}

sub get_clusters {
	my ($self) = @_;
	return $self->{_clusters};
}

sub get_image_url {
	my ($self) = @_;
	return $self->{_page_data}{location}{standard};
}

sub get_doctype {
	my ($self) = @_;
	unless (defined($self->{_clusters})) {
		carp("get_doctype called on OWD::Page object before annotations have been clustered");
		return;
	}
	if (ref($self->{_clusters}{doctype}[0]) ne "OWD::Cluster") {
		return;
	}
	my $consensus_annotation = $self->{_clusters}{doctype}[0]->get_consensus_annotation();
	if (ref($consensus_annotation) ne 'OWD::ConsensusAnnotation') {
		return;
	}
	else {
		return $self->{_clusters}{doctype}[0]->get_consensus_annotation()->get_string_value();
	}
}

sub num_classifications {
	my ($self) = @_;
	if (defined $self->{_classifications}) {
		return scalar @{$self->{_classifications}};
	}
	else {
		return 0;
	}
}

sub cluster_tags {
	my ($self) = @_;
	# create a data structure of annotations, grouped first by type, then by user
	# For each tag type, use the annotations by the user with the most contributions for that
	# tag type to create a skeleton cluster layout, then try to match the tags of this type
	# from other users to these clusters.
	$logger->trace("cluster_tags called");
	my $annotations_by_type_and_user = $self->get_annotations_by_type_and_user();
	foreach my $user (keys %{$annotations_by_type_and_user->{doctype}}) {
		#push @{$self->{_clusters}{doctype}}, $annotations_by_type_and_user->{doctype}{$user}[0];
		if (!defined($self->{_clusters}{doctype})) {
			push @{$self->{_clusters}{doctype}}, OWD::Cluster->new($self,$annotations_by_type_and_user->{doctype}{$user}[0]);
		}
		else {
			my $cluster = $self->{_clusters}{doctype}[0];
			$cluster->add_annotation($annotations_by_type_and_user->{doctype}{$user}[0]);
		}
	}
	foreach my $type (sort keys %$annotations_by_type_and_user) {
		next if $type eq 'doctype';
		# for this tag type, who has the most tags? Use their tags to create the skeleton cluster layout
		my $user_annotations_by_type_popularity = _num_tags_of_type($annotations_by_type_and_user->{$type});
		my $first_user_for_this_type = 1;
		foreach my $num_annotations (reverse sort {$a <=> $b} keys %$user_annotations_by_type_popularity) {
			foreach my $username (sort keys %{$user_annotations_by_type_popularity->{$num_annotations}}) {
				if ($first_user_for_this_type) {
					# This is the top user for the tag type, so create a new cluster for each of their tags
					foreach my $annotation (@{$user_annotations_by_type_popularity->{$num_annotations}{$username}}) {
						push @{$self->{_clusters}{$type}}, OWD::Cluster->new($self,$annotation);
					}
					$first_user_for_this_type = 0;
				}
				else {
					foreach my $annotation (@{$user_annotations_by_type_popularity->{$num_annotations}{$username}}) {
						$self->_match_annotation_against_existing($annotation);
					}
				}
			}
		}
	}
	foreach my $cluster_type (keys %{$self->{_clusters}}) {
		foreach my $cluster (@{$self->{_clusters}{$cluster_type}}) {
			if ($cluster->count_annotations() <= 1) {
				my $annotation = $cluster->{_annotations}[0];
				my $id = $annotation->get_id();
				my $string = $annotation->get_string_value();
				my $error = {
					'type'			=> 'cluster_error; single_annotation_cluster',
					'detail'		=> "annotation '$id' ($string) can't be clustered with any other annotations",
					'annotation'	=> $annotation->{_annotation_data},
					'annotation_id'	=> $annotation->get_id(),
				};
				# TODO should use an accessor to get the annotation data above
				$self->data_error($error);
			}
		}
	}
}

sub _match_annotation_against_existing {
	my ($self, $new_annotation) = @_;
	# for each cluster for this type so far, try matching new tag to it
	# find the most similar nearby tag. If there aren't any, start a new cluster.
	my $type = $new_annotation->get_type();
	my $new_annotation_contributor = $new_annotation->{_classification}->get_classification_user();
	my $annotation_distance_from_cluster;
	my $annotation_similarity_to_cluster;
	for (my $cluster_num = 0; $cluster_num <  @{$self->{_clusters}{$type}}; $cluster_num++) {
		# first check that the contributor of $new_annotation doesn't already have an annotation in
		# the cluster we are checking
		if ($self->{_clusters}{$type}[$cluster_num]->has_contributor($new_annotation_contributor)) {
			next;
		}
		# check for distance (x/y)
		# If this is a diaryDate field, we are deliberately skewing the y axis value as it provides a more accurate result
		my @coords_to_test = @{$new_annotation->get_coordinates()};
		if ($type eq 'diaryDate') {
			$coords_to_test[1] += $diaryDate_y_axis_skew;
		}
		my $distance = acceptable_distance($type,\@coords_to_test,$self->{_clusters}{$type}[$cluster_num]->get_centroid());
		if (defined($distance)) {
			$annotation_distance_from_cluster->{$cluster_num} = $distance;
		}
	}
	if (defined($annotation_distance_from_cluster)) {
		# we found at least one sufficiently close cluster of the right type.
		# select the best cluster
		# sort by cluster distance, then try any potential matches for note string similarity
		foreach my $cluster_num (sort {$annotation_distance_from_cluster->{$a} <=> $annotation_distance_from_cluster->{$b}} keys %{$annotation_distance_from_cluster}) {
			# TODO: Cause of error. Sometimes when two clusters are close to each other, a new annotation
			# can be closer to the wrong cluster. Clustering needs to take account of cluster similarity,
			# not just distance, when deciding which of two clusters to file an annotation in.
			# Test on clustering of diaryDate "15 Aug 1914" for GWD0000001 p4.
			@{$annotation_similarity_to_cluster->{$cluster_num}}{'score','length'} = @{similarity($type, $self->{_clusters}{$type}[$cluster_num]->get_first_annotation(),$new_annotation)};
		}
		# use the closest cluster unless the second closest cluster is identical to the new
		# annotation, or is less than half the score of the nearest cluster.
		my $selected_cluster;
		# @close_clusters is a list of clusters in order of distance
		my @close_clusters = sort {$annotation_distance_from_cluster->{$a} <=> $annotation_distance_from_cluster->{$b} } keys %$annotation_distance_from_cluster;
		# The above line can lead to inconsistent results if two or more clusters are exactly the same distance
		# from the annotation we are trying to cluster, as these same-distance clusters can be returned in
		# an arbitrary and changeable order. To resolve this, if the nearby clusters are exactly the same distance
		# and exactly the same similarity score, return them in array index order (still arbitrary, but at least
		# not changeable)
		for (my $i = 0; $i < @close_clusters - 1; $i++) {
			if ($annotation_distance_from_cluster->{ $close_clusters[$i] } == $annotation_distance_from_cluster->{ $close_clusters[$i+1] }) {
				if ($annotation_similarity_to_cluster->{ $close_clusters[$i] }{score} == $annotation_similarity_to_cluster->{ $close_clusters[$i+1] }{score}) {
					if ($close_clusters[$i] > $close_clusters[$i+1]) {
						@close_clusters[$i,$i+1] = @close_clusters[$i+1,$i];
						# TODO: if we re-ordered $i and $i+1 should we start the sort from 0 again?
						# Otherwise three consecutive identical distance tags in reverse index order would not be
						# sorted correctly
					}
				}
			}
		}
		# if the nearest cluster has a similarity score of 0 (identical)
		# OR if there is only one cluster nearby and the similarity score is less than half the length - 1
		if ($annotation_similarity_to_cluster->{$close_clusters[0]}{score} == 0 
			|| ( @close_clusters == 1 && $annotation_similarity_to_cluster->{$close_clusters[0]}{score} <= int($annotation_similarity_to_cluster->{$close_clusters[0]}{length} /2) - 1 ) ) {
			$selected_cluster = $close_clusters[0];
		}
		elsif (@close_clusters > 1) {
			# if there is more than one nearby cluster, find the cluster with the lowest similarty score (ie most similar)
			my $best_cluster_so_far;
			foreach my $cluster (@close_clusters) {
				if (!defined($best_cluster_so_far->{score}) || $best_cluster_so_far->{score} > $annotation_similarity_to_cluster->{$cluster}{score}) {
					@{$best_cluster_so_far}{'score','number'} = ($annotation_similarity_to_cluster->{$cluster}{score},$cluster);
				}
			}
			$selected_cluster = $best_cluster_so_far->{number};
		}
		if (defined $selected_cluster) {
			$self->{_clusters}{$type}[$selected_cluster]->add_annotation($new_annotation);
		}
		else {
			# if we get to here, though there were nearby clusters, they were too different to be able
			# to add $new_annotation to the cluster. In this case we should create a new cluster.
			push @{$self->{_clusters}{$type}}, OWD::Cluster->new($self,$new_annotation);
		}
	}
	else {
		# create a new cluster
		push @{$self->{_clusters}{$type}}, OWD::Cluster->new($self,$new_annotation);
	}
}

sub dump_clusters {
	my ($self,$type_to_dump) = @_;
	foreach my $cluster_type (keys %{$self->{_clusters}}) {
		next if (defined $type_to_dump && $cluster_type ne $type_to_dump);
		print "$cluster_type\n";
		my $cluster_num = 0;
		foreach my $cluster (@{$self->{_clusters}{$cluster_type}}) {
			$cluster_num++;
			print "  Cluster #$cluster_num\n";
			print "    Num annotations: ", $cluster->count_annotations(), "\n";
			my $median_centroid = $cluster->get_median_centroid();
			print "    Median centroid: $median_centroid->[0],$median_centroid->[1]\n";
			print "    Annotations:\n";
			my $annotation_num = 0;
			foreach my $annotation (@{$cluster->{_annotations}}) {
				$annotation_num++;
				print "      ($annotation_num) $annotation->{_annotation_data}{id}\n";
			}
		} 
	}
}

sub acceptable_distance {
	my ($type, $coord1, $coord2) = @_;
	# acceptable difference is a combination of a maximum x distance, a maximum y distance, and a 
	# maximum total distance (because there needs to be more tolerance on the x axis than the y axis)
	# TODO: Sometimes an entity is split over two lines in the diary (eg on page AWD000004x, the 22nd
	# August "march to/ Quievrain" is tagged at ~(67,31) by three users, but at (29,34) by one other)
	# Find some way of testing whether tags cluster better if we subtract x38 and add y3, but only 
	# for tags at the left edge or right edge of the page!
	my $x_max;
	my $y_max;
	my $dist_max;
	if ($type eq 'person') {
		$x_max = 12;
		$y_max = 3;
		$dist_max = 12;
	}
	elsif ($type eq 'place') {
		$x_max = 20;
		$y_max = 3;
		$dist_max = 20;
	}
	elsif ($type eq 'diaryDate') {
		$x_max = 15;
		$y_max = 7;
		$dist_max = 15;
	}
	elsif ($type eq 'activity') {
		$x_max = 30;
		$y_max = 5;
		$dist_max = 30;
	}
	else {
		$x_max = 9;
		$y_max = 3;
		$dist_max = 8;
	}
	my $x_dist = abs($coord1->[0] - $coord2->[0]);
	my $y_dist = abs($coord1->[1] - $coord2->[1]);
	if ($x_dist <= $x_max && $y_dist <= $y_max) {
		my $diff = distance($coord1,$coord2);
		if ($diff <= $dist_max) {
			return $diff;
		}
		else {
			return;
		}
	}
	else {
		return;
	}
}

sub distance {
	my ($coord1,$coord2) = @_;
	return sqrt( ( ($coord1->[0] - $coord2->[0])**2 ) + ( ($coord1->[1] - $coord2->[1])**2) );
}

sub similarity {
	my ($type, $cluster_annotation, $new_annotation) = @_;
	my ($score,$length);
	if ($type eq 'activity' || $type eq 'domestic' || $type eq 'weather' || $type eq 'casualties') {
		return [0,0];
	}
	elsif ($type eq 'person') {
		# look for a low score on surname and firstname
		$score = Text::LevenshteinXS::distance($cluster_annotation->get_field('surname'),$new_annotation->get_field('surname'));
		$length = length($cluster_annotation->get_field('surname'));
		if (defined($new_annotation->get_field('first')) && defined($cluster_annotation->get_field('first'))) {
			$score += Text::LevenshteinXS::distance($cluster_annotation->get_field('first'),$new_annotation->get_field('first'));
			$length += length($cluster_annotation->get_field('first'));
		}
	}
	elsif ($type eq 'place') {
		$score = Text::LevenshteinXS::distance($cluster_annotation->get_field('place'),$new_annotation->get_field('place'));
		$length = length($cluster_annotation->get_field('place'));
	}
	# TODO: Add a new case for activity types - currently scoring them 0 (identical) regardless of 
	# value is probably causing problems. Do an analysis to assign meaningful scores depending on tyoe though
	# eg. enemy_activity, fire and attack are used interchangeably (incorrectly probably, but still)
	else {
		my $type = $new_annotation->get_type();
		if ($type ne 'diaryDate' && $type ne 'time' && $type ne 'place' && $type ne 'activity' && $type ne 'domestic' && $type ne 'weather' && $type eq 'weather') {
			undef;
		}
		$score = Text::LevenshteinXS::distance($cluster_annotation->get_string_value(),$new_annotation->get_string_value());
		$length = length($cluster_annotation->get_string_value());
	}
	return [$score,$length];
}

sub establish_consensus {
	my ($self) = @_;
	$logger->debug("Establishing consensus for page", $self->get_page_num());
	foreach my $type (keys %{$self->{_clusters}}) {
		foreach my $cluster (@{$self->{_clusters}{$type}}) {
			$cluster->establish_consensus();
		}
	}
}

sub _num_tags_of_type {
	my ($annotations_grouped_by_user) = shift;
	my $user_annotations_by_num_uses;
	foreach my $user (keys %$annotations_grouped_by_user) {
		my $num_tags_for_user = @{$annotations_grouped_by_user->{$user}};
		$user_annotations_by_num_uses->{$num_tags_for_user}{$user} = $annotations_grouped_by_user->{$user};
	}
	return $user_annotations_by_num_uses;
}

sub cluster_tags_using_cluster_algorithm {
	# separating annotations that have been too aggressively clustered is REALLY complicated. Going
	# back to previous clustering algorithm
	# DELETE THIS?
	my ($self) = @_;
	my $annotations_by_type = $self->get_annotations_by_type(); # store annotations by type for the main clustering routine
	# ^ destroy this circular ref when the page is destroyed
	foreach my $type (keys %$annotations_by_type) {
		my $annotations = $annotations_by_type->{$type};
		# Use separate tolerances for diaryDate co-ordinates as some users were ensuring that
		# the ruler correctly divided entries, while others were tagging the precise location
		# of the date entry. Both are right, but those who used the ruler method will produce
		# more accurate results.
		my $clp;
		if ($type eq 'diaryDate') {
			$clp = Algorithm::ClusterPoints->new(
						dimension		=> 2,
						radius			=> 20.0,
						minimum_size 	=> 1,
						scales			=> [1,4],
			);
		}
		else {
			$clp = Algorithm::ClusterPoints->new(
						dimension		=> 2,
						radius			=> 24.0,
						minimum_size 	=> 1,
						scales			=> [2,7],
			);
		}
		if ($type eq "doctype") {
			# treat this annotation type separately as it doesn't have co-ordinates and 
			# only occurs once per user per page.
			#my $consensus_key = OWD::Processor->get_key_with_most_array_elements($annotations);
			push @{$self->{_clusters}{doctype}}, $annotations_by_type->{$type};
		}
		else {
			# We have filtered the options by type, now we should be confident enough to
			# cluster by co-ordinate, then for each cluster, check if the note field is close enough
			foreach my $annotation (@{$annotations}) {
				$clp->add_point(@{$annotation->{_annotation_data}{coords}});
			}
			my @clusters = $clp->clusters_ix;
			foreach my $cluster (@clusters) {
				my $this_cluster;
				foreach my $annotation_number (@{$cluster}) {
					push @{$this_cluster}, $annotations->[$annotation_number];
				}
				push @{$self->{_clusters}{$type}}, $this_cluster;
			}
		}
		# Once we have an initial set of clusters, check for any annotations that
		# have been too aggressively clustered, and move annotations between clusters
		# as appropriate.
		$self->_tidy_clusters();
	}
}

sub _tidy_clusters {
	# This was needed to deal with aggressively clustered annotations when using the ClusterPoints
	# algorithm. DELETE THIS
	my ($self) = @_;
	# Check the annotations in each cluster to see if the same user has more than one annotation
	# If so, chances are we've clustered two entities together by being too lenient on x/y coords.
	# Review each annotation in the cluster, calculating its distance and "similarity" to other
	# annotations in the cluster (or nearby annotations from any cluster?), then optimise the clusters
	# by moving annotations between clusters.
	foreach my $type (keys %{$self->{_clusters}}) {
		next if $type eq 'doctype';
		foreach my $cluster (@{$self->{_clusters}{$type}}) {
			my $cluster_annotations_per_user;
			foreach (my $annotation_number = 0; $annotation_number < @$cluster; $annotation_number++) {
				my $annotation = $cluster->[$annotation_number];
				my $user = $annotation->get_classification()->get_classification_user();
				push @{$cluster_annotations_per_user->{$user}},$annotation_number;
			}
			foreach my $user (keys %$cluster_annotations_per_user) {
				if (@{$cluster_annotations_per_user->{$user}} > 1) {
					my @separate_entities;
					foreach my $annotation_number (@{$cluster_annotations_per_user->{$user}}) {
						push @separate_entities, $cluster->[$annotation_number]->get_coordinates()
					}
					my $shortest_distance = get_shortest_distance_between_points(\@separate_entities);
					undef;
				}
			}
		}
	}
}

sub get_shortest_distance_between_points {
	my ($points) = @_;
	my @distances;
	for (my $i=0; $i<@$points-1; $i++) {
		for (my $j = $i+1; $j < @$points; $j++) {
			push @distances, 
				sqrt( (($points->[$i][0] - $points->[$j][0])^2)
					+(($points->[$i][1] - $points->[$j][1])^2) );
		}
	}
	return (sort @distances)[0];
}

sub get_annotations_by_type {
	my ($self) = @_;
	my $annotations_by_type = {};
	foreach my $classification (@{$self->{_classifications}}) {
		#push @{$annotations_by_type->{doctype}{$classification->get_doctype()}}, $classification;
		my $annotations_by_type_this_classification = $classification->get_annotations_by_type();
		while (my ($type, $annotations) = each %{$annotations_by_type_this_classification}) {
			push @{$annotations_by_type->{$type}}, @$annotations;
		}
	}
	return $annotations_by_type;
}

sub get_annotations_by_type_and_user {
	my ($self) = @_;
	my $annotations_by_type = {};
	foreach my $classification (@{$self->{_classifications}}) {
		my $user = $classification->get_classification_user();
		my $annotations_by_type_this_classification = $classification->get_annotations_by_type();
		foreach my $type (keys %$annotations_by_type_this_classification) {
			$annotations_by_type->{$type}{$user} = $annotations_by_type_this_classification->{$type};
		}
	}
	return $annotations_by_type;
}

sub resolve_uncertainty {
	my ($self) = @_;
	foreach my $cluster_type (keys %{$self->{_clusters}}) {
		foreach my $cluster (@{$self->{_clusters}{$cluster_type}}) {
			if (defined(my $consensus_annotation = $cluster->get_consensus_annotation())) {
				# It was possible to get a consensus
				$consensus_annotation->resolve_disputes();
			}
			else {
				# There is no consensus annotation yet
				if ($cluster->count_annotations() == 1) {
					# We can't compute or infer consensus from a single user annotation
				}
				else {
					undef;
					# possible methods to fix disputes
					# - for places, if one place is a substring of the other, try both against Geonames
					# 	and if they are close to each other, use 1) the longer name 2) the one with the best category
					#   eg "La Voue le Pretre" vs "Pretre" and "Jovey le Chatel" vs "Chatel"
				}
			}
		}
	}
}

sub get_date_range {
	my ($self) = @_;
	my $date_range;
	# TODO: calculate earliest, latest and median date, return array/hash of results.
	if (defined($self->{_clusters}{diaryDate})) {
		my $date_parser = DateTime::Format::Natural->new();
		foreach my $cluster (@{$self->{_clusters}{diaryDate}}) {
			my $consensus_annotation = $cluster->get_consensus_annotation();
			if (defined($consensus_annotation)) {
				my $note = $consensus_annotation->get_note();
				if (ref($note) eq "ARRAY") {
					next;
				}
				my $date_string = $consensus_annotation->get_string_value();
				my $date = $date_parser->parse_datetime($date_string);
				if (!defined($date_range->{min})) {
					$date_range->{min} = $date;
				}
				elsif (DateTime::compare($date_range->{min},$date) > 0) {
					$date_range->{min} = $date;
				}
				if (!defined($date_range->{max})) {
					$date_range->{max} = $date;
				}
				elsif (DateTime::compare($date_range->{max},$date) < 0) {
					$date_range->{max} = $date;
				}
			}
			else {
				# should we record the clusters that don't have consensus somewhere for easy access later?
				if ($cluster->count_annotations > 1) {					
					undef;
				}
			}
		}
		undef;
	}
	return $date_range;
}

sub resolve_diaryDate_disputes {
	my ($self) = @_;
	if (defined $self->{_clusters}{diaryDate}) {
		foreach my $cluster (@{$self->{_clusters}{diaryDate}}) {
			next if (!defined($cluster->get_consensus_annotation()) && $cluster->count_annotations() < 2);
			if (!defined($cluster->get_consensus_annotation())) {
				# a diaryDate cluster without a consensus annotation
				undef;
				next;
			}
			elsif (ref($cluster->get_consensus_annotation()->get_note()) eq "ARRAY") {
				# a diaryDate with a disputed consensus_annotation
				# If we get here, we failed to find a consensus on the first pass through the cluster
				# but we have enough contributions that we can try to infer the correct entry.
				# First we should get the two (or more) most popular values (there can't be a single
				# most popular value or it would have been selected in the first pass through establish_consensus() )
				my $value_counts = $cluster->_get_annotation_value_scores();
				my $surrounding_dates = $self->{_diary}->get_surrounding_dates_for($self->get_page_num(), ($cluster->get_median_centroid())->[1] );
				undef;
			}
			elsif ($cluster->get_consensus_annotation()->get_note() =~ /\d+ [A-Za-z]{3} \d{4}/) {
				next;
			}
			else {
				# something else
				undef;
				next;
			}
		}
	}
	undef;
}

sub data_error {
	my ($self, $error_hash) = @_;
	if (!defined $error_hash->{page}) {
		$error_hash->{page} = {
			'subject_id'		=> $self->get_zooniverse_id(),
			'page_number'		=> $self->get_page_num(),
		};
	}
	$self->{_diary}->data_error($error_hash);
}

sub DESTROY {
	my ($self) = @_;
	foreach my $classification (@{$self->{_classifications}}) {
		$classification->DESTROY();
	}
	foreach my $type (keys %{$self->{_clusters}}) {
		foreach my $cluster (@{$self->{_clusters}{$type}}) {
			if (ref($cluster) ne 'OWD::Cluster') {
				undef;
			}
			$cluster->DESTROY();
		}
	}
	$self->{_diary} = undef;
}

1;