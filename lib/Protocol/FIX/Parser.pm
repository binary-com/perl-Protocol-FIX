package Protocol::FIX::Parser;

use strict;
use warnings;

use List::Util qw/first/;
use Protocol::FIX qw/humanize/;
use Protocol::FIX::TagsAccessor;
use Protocol::FIX::MessageInstance;

sub _parse_tag_pair {
    my ($protocol, $pair, $check_value) = @_;
    return unless $pair;

    if ($pair =~ /^(\d{1,3})($Protocol::FIX::TAG_SEPARATOR)(.*)$/) {
        my ($tag_id, $value) = ($1, $3);

        my $field = $protocol->{fields_lookup}->{by_number}->{$tag_id};
        return (undef, "Protocol error: unknown tag '$tag_id' in tag pair '" . Protocol::FIX::humanize($pair) . "'")
            unless $field;

        return unless defined $3;

        return ([$field, $value]) unless $check_value;

        return (undef, "Protocol error: value for field '" . $field->{name} . "' does not pass validation in tag pair '"
            . Protocol::FIX::humanize($pair) . "'")
            unless $field->check_raw($value);

        return ([$field, $value]);

    } else {
        if ($pair =~ /[\D$Protocol::FIX::TAG_SEPARATOR]+/)  {
            return (undef, "Protocol error: sequence '" . Protocol::FIX::humanize($pair) . "' does not match tag pair");
        }
        return;
    }
}

sub parse {
    my ($protocol, $buff_ref) = @_;
    my $consumed_length = 0;

    # this are fatal messages, i.e. point to developer error, hence we die
    die("buffer is undefined, cannot parse") unless defined $buff_ref;
    die("buffer is not scalar reference") unless ref($buff_ref) eq 'SCALAR';

    my $begin_string = $protocol->{begin_string};
    my $buff_length = length($$buff_ref);

    # no enough data
    return if $buff_length < length($begin_string);

    if (substr($$buff_ref, 0, length($begin_string)) ne $begin_string) {
        return (undef, "Mismatch protocol introduction, expected: $begin_string");
    }

    # no enough data
    return if $buff_length == length($begin_string);

    my @header_pairs = split $Protocol::FIX::SEPARATOR, $$buff_ref, 3;

    # minimal required fields: BeginString, MessageLength, MessageType, CheckSum
    return (undef, "Protocol error: separator expecter right after $begin_string")
        if (@header_pairs < 2);

    $consumed_length += length($begin_string) + 1;

    # extract, but do not check-for-correctness body length
    my $body_length = do {
        my $pair_is_complete = @header_pairs > 2;
        my ($tag_pair, $err) = _parse_tag_pair($protocol, $header_pairs[1], $pair_is_complete);
        return (undef, $err) if $err;

        my ($field, $value) = @$tag_pair;
        if ($field->{name} ne 'BodyLength') {
            return (undef, "Protocol error: expected field 'BodyLength', but got '"
                . $field->{name} . "', in sequence '" . $header_pairs[1] . "'");
        }
        return unless $pair_is_complete;

        $consumed_length += length($header_pairs[1]) + 1;
        $value;
    };

    return if $buff_length <= $consumed_length + $body_length;
    my $trailer = substr($$buff_ref, $consumed_length + $body_length);

    # -1 is included as it is terminator / end of message boundary
    my @trailer_pairs = split $Protocol::FIX::SEPARATOR, $trailer, -1;

    # 3 tags expected: empty - checksum - empty(or may be new message)
    return if (@trailer_pairs < 3) || !$trailer_pairs[1];
    # from here we assume $body_length is valid

    my $checksum_pair = $trailer_pairs[1];
    my $body;
    my $checksum = do {
        my ($tag_pair, $err) = _parse_tag_pair($protocol, $checksum_pair, 1);
        return (undef, $err) if $err;

        my ($field, $value) = @$tag_pair;
        if ($field->{name} ne 'CheckSum') {
            return (undef, "Protocol error: expected field 'CheckSum', but got '"
                . $field->{name} . "', in sequence '" . $checksum_pair . "'");
        }

        my $is_number = ($value =~ /^\d{3}$/);

        if (!$is_number || ($is_number && ($value > 255))) {
            return (undef, "Protocol error: value for field '" . $field->{name} . "' does not pass validation in tag pair '"
                        . Protocol::FIX::humanize($checksum_pair) . "'")
        }

        $body = substr($$buff_ref, $consumed_length, $body_length);
        my $sum = 0;
        $sum += ord $_ for split //, $body;
        $sum %= 256;

        if ($sum != $value) {
            return (undef, "Protocol error: Checksum mismatch;  got $sum, expected $value for message '"
                        . Protocol::FIX::humanize($body) . "'");
        }
        $value;
    };
    my ($message, $errors) = _parse_body($protocol, \$body);
}

sub _parse_body {
    my ($protocol, $body_ref) = @_;
    my @pairs = split $Protocol::FIX::SEPARATOR, $$body_ref;

    my @tag_pairs = map {
        my ($tag_pair, $err) = _parse_tag_pair($protocol, $_, 1);
        return (undef, $err) if $err;
        $tag_pair;
    } @pairs;

    my $msg_type_pair = first { $_->[0]->{name} eq 'MsgType' } @tag_pairs;
    return (undef, "Protocol error: 'MsgType' was not found in body")
        unless $msg_type_pair;

    my ($field_msg_type, $msg_type) = @$msg_type_pair;
    my $message = $protocol->{messages_lookup}->{by_number}->{$msg_type};
    # we don't die, as it might be possible to use custom message types
    # http://fixwiki.org/fixwiki/MsgType
    return (undef, "Protocol error: MessageType '$msg_type' is not available")
        unless $message;

    my ($ta, $err) = _construct_tag_accessor($protocol, $message, \@tag_pairs, 1);
    return (undef, $err) if $err;

    return (new Protocol::FIX::MessageInstance($message, $ta));
};

sub _construct_tag_accessor_component {
    my ($protocol, $composite, $tag_pairs) = @_;
    my $field = $tag_pairs->[0]->[0];

    my $sub_composite_name = $composite->{field_to_component}->{$field->{name}};
    my $composite_desc = $composite->{composite_by_name}->{$sub_composite_name};
    my ($sub_composite, $required) = @$composite_desc;
    my ($ta, $error) = _construct_tag_accessor($protocol, $sub_composite, $tag_pairs, 0);
    return (undef, $error) if ($error);
    return ([$sub_composite => $ta]);
}

sub _construct_tag_accessor_field {
    my ($protocol, $composite, $tag_pairs) = @_;

    my ($field, $value) = @{ shift(@$tag_pairs) };
    my $humanized_value = $field->has_mapping
        ? $field->{values}->{by_id}->{$value}
        : $value
        ;
    return ([$field => $humanized_value]);
}

sub _construct_tag_accessor {
    my ($protocol, $composite, $tag_pairs, $fail_on_missing) = @_;

    my @direct_pairs;
    while (my $pair = shift(@$tag_pairs)) {
        my ($field, $value) = @$pair;

        next if exists $protocol->managed_composites->{$field->{name}};

        my $owner = $composite->{field_to_component}->{$field->{name}};

        if ($owner && ($owner ne $composite->{name})) {
            unshift @$tag_pairs, $pair;
            my ($ta_descr, $error) = _construct_tag_accessor_component($protocol, $composite, $tag_pairs);
            return (undef, $error) if ($error);
            push @direct_pairs, $ta_descr->[0] => $ta_descr->[1];
        } elsif ($composite->{composite_by_name}->{$field->{name}}) {
            my $composite_desc = $composite->{composite_by_name}->{$field->{name}};
            my ($sub_composite, $required) = @$composite_desc;
            if ($field->{type} eq 'NUMINGROUP') {
                my @tag_accessors;
                for (1 .. $value) {
                    my ($ta) = _construct_tag_accessor($protocol, $sub_composite, $tag_pairs, 0);
                    return (undef, "cannot construct ...") unless $ta;
                    push @tag_accessors, $ta;
                }
                my $group_accessor = Protocol::FIX::TagsAccessor->new([ $sub_composite => \@tag_accessors]);
                push @direct_pairs, $sub_composite => \@tag_accessors;
            } else {
                unshift @$tag_pairs, $pair;
                my ($ta_descr, $error) = _construct_tag_accessor_field($protocol, $composite, $tag_pairs);
                return (undef, $error) if ($error);
                push @direct_pairs, $ta_descr->[0] => $ta_descr->[1];
            }
        } else {
            return (undef, "Protocol error: field '" . $field->{name} . "' was not expected in"
                . $composite->{type} . "'" . $composite->{type} . "'")
                if ($fail_on_missing);

            last;
        }
    }
    return (@direct_pairs ? Protocol::FIX::TagsAccessor->new(\@direct_pairs) : ());
}

1;