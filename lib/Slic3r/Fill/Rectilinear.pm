package Slic3r::Fill::Rectilinear;
use Moo;

extends 'Slic3r::Fill::Base';
with qw(Slic3r::Fill::WithDirection);

has '_min_spacing'          => (is => 'rw');
has '_line_spacing'         => (is => 'rw');
has '_diagonal_distance'    => (is => 'rw');
has '_line_oscillation'     => (is => 'rw');

use Slic3r::Geometry qw(scale unscale scaled_epsilon);
use Slic3r::Geometry::Clipper qw(intersection_pl);

sub horizontal_lines { 0 }

sub start_x_per_layer () { (0, 1, 0, 1) }
sub start_y_per_layer () { (1, 1, 1, 1) }
sub loop_mult_per_layer () { (1, -1, 1, -1) }

sub fill_surface {
    my $self = shift;
    my ($surface, %params) = @_;
    
    # rotate polygons so that we can work with vertical lines here
    my $expolygon = $surface->expolygon->clone;
    my $rotate_vector = $self->infill_direction($surface);
    $self->rotate_points($expolygon, $rotate_vector);
    
    $self->_min_spacing(scale $self->spacing);
    $self->_line_spacing($self->_min_spacing / $params{density});
    $self->_diagonal_distance($self->_line_spacing * 2);
    $self->_line_oscillation($self->_line_spacing - $self->_min_spacing);  # only for Line infill
    my $bounding_box = $expolygon->bounding_box;
    
    # define flow spacing according to requested density
    if ($params{density} == 1 && !$params{dont_adjust}) {
        $self->_line_spacing($self->adjust_solid_spacing(
            width       => $bounding_box->size->x,
            distance    => $self->_line_spacing,
        ));
        $self->spacing(unscale $self->_line_spacing);
    } else {
        # extend bounding box so that our pattern will be aligned with other layers
        $bounding_box->merge_point(Slic3r::Point->new(
            $bounding_box->x_min - ($bounding_box->x_min % $self->_line_spacing),
            $bounding_box->y_min - ($bounding_box->y_min % $self->_line_spacing),
        ));
    }
    
    my $layer_num = $self->layer_id / $surface->thickness_layers;

    # Offset
    my $offset = $self->infill_offset($surface) * $self->_line_spacing;
    my $spacing = $self->_line_spacing;

    # generate the basic pattern
    my $x_max = $bounding_box->x_max + scaled_epsilon;
    my @lines  = ();


    my $layer_key = $layer_num % 4;
    
    my @start_x_per_layer = $self->start_x_per_layer;
    my @start_y_per_layer   = $self->start_y_per_layer;
    my @loop_mult_per_layer = $self->loop_mult_per_layer;    

    my $start_x = $bounding_box->x_min;
    my $end_x = $x_max;
    if ($start_x_per_layer[$layer_key]) {
        $start_x = $x_max;
        $end_x = $bounding_box->x_min;
    }

    my $start_y = $bounding_box->y_min;
    my $end_y = $bounding_box->y_max;
    if ($start_y_per_layer[$layer_key]) {
        $start_y = $bounding_box->y_max;
        $end_y = $bounding_box->y_min;
    }

    my $loop_mult = $loop_mult_per_layer[$layer_key];

    print "layer $layer_num: start_x=$start_x start_y=$start_y loop_mult=$loop_mult\n";

    for (my $x = $start_x; $x*$loop_mult <= $end_x*$loop_mult; $x += $self->_line_spacing * $loop_mult) {
        # print "x=$x ";
        push @lines, $self->_line($#lines, $x+$offset, $start_y, $end_y);
    }
    print "\n";
    if ($self->horizontal_lines) {
        my $y_max = $bounding_box->y_max + scaled_epsilon;
        for (my $y = $bounding_box->y_min; $y <= $y_max; $y += $self->_line_spacing) {
            push @lines, Slic3r::Polyline->new(
                [$bounding_box->x_min, $y],
                [$bounding_box->x_max, $y],
            );
        }
    }
    
    # clip paths against a slightly larger expolygon, so that the first and last paths
    # are kept even if the expolygon has vertical sides
    # the minimum offset for preventing edge lines from being clipped is scaled_epsilon;
    # however we use a larger offset to support expolygons with slightly skewed sides and 
    # not perfectly straight
    my @polylines = @{intersection_pl(\@lines, $expolygon->offset(+scale 0.02))};
    
    my $extra = $self->_min_spacing * &Slic3r::INFILL_OVERLAP_OVER_SPACING;
    foreach my $polyline (@polylines) {
        my ($first_point, $last_point) = @$polyline[0,-1];
        if ($first_point->y > $last_point->y) { #>
            ($first_point, $last_point) = ($last_point, $first_point);
        }
        $first_point->set_y($first_point->y - $extra);  #--
        $last_point->set_y($last_point->y + $extra);    #++
    }
    
    # connect lines
    unless ($params{dont_connect} || !@polylines) {  # prevent calling leftmost_point() on empty collections
        # offset the expolygon by max(min_spacing/2, extra)
        my ($expolygon_off) = @{$expolygon->offset_ex($self->_min_spacing/2)};
        my $collection = Slic3r::Polyline::Collection->new(@polylines);
        @polylines = ();
        
        foreach my $polyline (@{$collection->chained_path_from($collection->leftmost_point, 0)}) {
            if (@polylines) {
                my $first_point = $polyline->first_point;
                my $last_point = $polylines[-1]->last_point;
                my @distance = map abs($first_point->$_ - $last_point->$_), qw(x y);
                
                # TODO: we should also check that both points are on a fill_boundary to avoid 
                # connecting paths on the boundaries of internal regions
                if ($self->_can_connect(@distance) && $expolygon_off->contains_line(Slic3r::Line->new($last_point, $first_point))) {
                    $polylines[-1]->append_polyline($polyline);
                    next;
                }
            }
            
            # make a clone before $collection goes out of scope
            push @polylines, $polyline->clone;
        }
    }
    
    # paths must be rotated back
    $self->rotate_points_back(\@polylines, $rotate_vector);
    
    return @polylines;
}

sub _line {
    my ($self, $i, $x, $y_min, $y_max) = @_;
    
    return Slic3r::Polyline->new(
        [$x, $y_min],
        [$x, $y_max],
    );
}

sub _can_connect {
    my ($self, $dist_X, $dist_Y) = @_;
    
    return $dist_X <= $self->_diagonal_distance
        && $dist_Y <= $self->_diagonal_distance;
}


package Slic3r::Fill::Line;
use Moo;
extends 'Slic3r::Fill::Rectilinear';

use Slic3r::Geometry qw(scaled_epsilon);

sub _line {
    my ($self, $i, $x, $y_min, $y_max) = @_;
    
    if ($i % 2) {
        return Slic3r::Polyline->new(
            [$x - $self->_line_oscillation, $y_min],
            [$x + $self->_line_oscillation, $y_max],
        );
    } else {
        return Slic3r::Polyline->new(
            [$x, $y_min],
            [$x, $y_max],
        );
    }
}

sub _can_connect {
    my ($self, $dist_X, $dist_Y) = @_;
    
    my $TOLERANCE = 10 * scaled_epsilon;
    return ($dist_X >= ($self->_line_spacing - $self->_line_oscillation) - $TOLERANCE)
        && ($dist_X <= ($self->_line_spacing + $self->_line_oscillation) + $TOLERANCE)
        && $dist_Y <= $self->_diagonal_distance;
}


package Slic3r::Fill::Grid;
use Moo;
extends 'Slic3r::Fill::Rectilinear';

sub angles () { [0] }
sub horizontal_lines { 1 }


package Slic3r::Fill::AlignedRectilinear;
use Moo;
extends 'Slic3r::Fill::Rectilinear';

sub angles () { [0, 0] }
sub offset () { [0, 0] }


package Slic3r::Fill::AlignedOffsetRectilinear;
use Moo;
extends 'Slic3r::Fill::Rectilinear';

sub angles () { [0, 0] }
sub offset () { [0, 0.5] }
sub start_x_per_layer () { (1, 1, 0, 0) }
sub start_y_per_layer () { (0, 1, 1, 0) }
sub loop_mult_per_layer () { (-1, -1, 1, 1) }

1;
