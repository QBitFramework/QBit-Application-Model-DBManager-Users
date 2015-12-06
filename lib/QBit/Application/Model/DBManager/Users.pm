package QBit::Application::Model::DBManager::Users;

use qbit;

use base qw(QBit::Application::Model::DBManager);

use Data::Rmap ':all';

__PACKAGE__->model_accessors(db => 'QBit::Application::Model::DB::Users');

__PACKAGE__->register_rights(
    [
        {
            name        => 'users',
            description => sub {gettext('Rights for users')},
            rights      => {
                users_view => d_gettext('Right to view list of users'),
                users_add  => d_gettext('Right to add new user'),
                users_edit => d_gettext('Right to edit user'),
            },
        }
    ]
);

__PACKAGE__->model_fields(__PACKAGE__->get_model_users_fields,);

__PACKAGE__->model_filter(
    db_accessor => 'db',
    fields      => {__PACKAGE__->get_model_users_filter_fields,}
);

sub get_model_users_fields {
    return (
        id        => {db => TRUE, pk    => TRUE, default => TRUE, label => d_gettext('ID')},
        create_dt => {db => TRUE, label => d_gettext('Create date')},
        login        => {db => TRUE, default => TRUE, label => d_gettext('Login')},
        mail         => {db => TRUE, default => TRUE, label => d_gettext('Mail')},
        name         => {db => TRUE, label   => d_gettext('Name')},
        midname      => {db => TRUE, label   => d_gettext('Midname')},
        surname      => {db => TRUE, label   => d_gettext('Surname')},
        extra_fields => {
            depends_on => ['id'],
            label      => d_gettext('Extra fields'),
            get        => sub {
                $_[0]->{'__EXTRA_FIELDS__'}{$_[1]->{'id'}} // {};
              }
        }
    );
}

sub get_model_users_filter_fields {
    return (
        id        => {type => 'number'},
        create_dt => {type => 'text'},
        login     => {type => 'text'},
        mail      => {type => 'text'},
        name      => {type => 'text'},
        midname   => {type => 'text'},
        surname   => {type => 'text'},
    );
}

sub query {
    my ($self, %opts) = @_;

    my $filter = $self->db->filter($opts{'filter'});

    unless ($self->check_rights('users_view')) {
        $filter->and(['id' => '=' => \$self->get_option('cur_user', {})->{'id'}]);
    }

    return $self->db->query->select(
        table  => $self->db->users,
        fields => $opts{'fields'}->get_db_fields(),
        filter => $filter,
    );
}

sub pre_process_fields {
    my ($self, $fields, $result) = @_;

    my $user_ids = array_uniq(map {$_->{'id'}} @$result);

    if ($fields->need('extra_fields')) {
        $fields->{'__EXTRA_FIELDS__'} = {};

        my $extra_fields = $self->db->users_extra_fields->get_all(
            fields => [qw(user_id key value is_json)],
            filter => {user_id => $user_ids}
        );

        foreach my $rec (@$extra_fields) {
            push(
                @{$fields->{'__EXTRA_FIELDS__'}{$rec->{'user_id'}}{$rec->{'key'}}},
                $rec->{'is_json'} ? from_json($rec->{'value'}) : $rec->{'value'}
            );
        }
    }
}

sub add {
    my ($self, %opts) = @_;

    throw Exception::Denied gettext("You can't add user") unless $self->check_rights('users_add');

    $self->_trim(\%opts);

    $self->check_user(\%opts);

    $opts{'create_dt'} //= curdate(oformat => 'db_time');

    my $extra_fields = delete($opts{'extra_fields'});

    my $id;
    $self->db->transaction(
        sub {
            $id = $self->db->users->add(\%opts);

            if (defined($extra_fields)) {
                $extra_fields = $self->normalization_extra_fields($extra_fields);

                my @data = ();
                foreach my $key (keys(%$extra_fields)) {
                    push(@data,
                        map {{user_id => $id, key => $key, value => $_->{'value'}, is_json => $_->{'is_json'}}}
                          @{$extra_fields->{$key}});
                }

                $self->db->users_extra_fields->add_multi(\@data) if @data;
            }
        }
    );

    return $id;
}

sub _trim {
    my ($self, $opts) = @_;

    rmap_all {$_ =~ s/^\s+|\s+$//g if defined($_) && !ref($_)} $opts;
}

sub normalization_extra_fields {
    my ($self, $extra_fields) = @_;

    throw Exception::BadArguments gettext('Expected hash') unless ref($extra_fields) eq 'HASH';

    rmap_to(
        sub {
            unless (in_array(ref($_), ['', 'ARRAY', 'HASH'])) {
                die gettext('Option "extra_fields" must not contain something other than a array, scalar or hash');
            }
        },
        ALL | CODE,
        $extra_fields
    );

    foreach my $key (keys(%$extra_fields)) {
        if (ref($extra_fields->{$key}) eq 'HASH') {
            $extra_fields->{$key} = [
                {
                    value   => to_json($extra_fields->{$key}),
                    is_json => TRUE
                }
            ];
        } elsif (ref($extra_fields->{$key}) eq 'ARRAY') {
            my @norm_data = ();

            foreach my $value (@{$extra_fields->{$key}}) {
                if (ref($value)) {
                    push(
                        @norm_data,
                        {
                            value   => to_json($value),
                            is_json => TRUE
                        }
                    );
                } else {
                    push(
                        @norm_data,
                        {
                            value   => $value,
                            is_json => FALSE
                        }
                    );
                }
            }

            $extra_fields->{$key} = \@norm_data;
        } else {
            $extra_fields->{$key} = [
                {
                    value   => $extra_fields->{$key},
                    is_json => FALSE
                }
            ];
        }
    }

    return $extra_fields;
}

sub edit {
    my ($self, $id, %opts) = @_;

    throw Exception::Denied gettext("You can't edit user") unless $self->check_rights('users_edit');

    $self->_trim(\%opts);

    $self->check_user(\%opts);

    my $exists_extra_fields = exists($opts{'extra_fields'});
    my $extra_fields        = delete($opts{'extra_fields'});

    $self->db->transaction(
        sub {
            $self->db->users->edit($id, \%opts) if %opts;

            if (defined($extra_fields)) {
                $extra_fields = $self->normalization_extra_fields($extra_fields);

                $self->db->users_extra_fields->delete(
                    $self->db->filter({user_id => $id, key => [keys(%$extra_fields)]}))
                  if %$extra_fields;

                my @data = ();
                foreach my $key (keys(%$extra_fields)) {
                    push(@data,
                        map {{user_id => $id, key => $key, value => $_->{'value'}, is_json => $_->{'is_json'}}}
                          @{$extra_fields->{$key}});
                }

                $self->db->users_extra_fields->add_multi(\@data) if @data;
            } elsif ($exists_extra_fields) {
                $self->db->users_extra_fields->delete($self->db->filter({user_id => $id}));
            }
        }
    );
}

sub check_user { }

TRUE;
