package MusicBrainz::Server::Data::Work;

use Moose;
use List::MoreUtils qw( uniq );
use MusicBrainz::Server::Entity::Work;
use MusicBrainz::Server::Data::Utils qw(
    defined_hash
    generate_gid
    hash_to_row
    load_subobjects
    merge_table_attributes
    placeholders
    query_to_list
    query_to_list_limited
);

extends 'MusicBrainz::Server::Data::CoreEntity';
with 'MusicBrainz::Server::Data::Role::Annotation' => { type => 'work' };
with 'MusicBrainz::Server::Data::Role::Name' => { name_table => 'work_name' };
with 'MusicBrainz::Server::Data::Role::Alias' => { type => 'work' };
with 'MusicBrainz::Server::Data::Role::Rating' => { type => 'work' };
with 'MusicBrainz::Server::Data::Role::Tag' => { type => 'work' };
with 'MusicBrainz::Server::Data::Role::Editable' => { table => 'work' };
with 'MusicBrainz::Server::Data::Role::BrowseVA';
with 'MusicBrainz::Server::Data::Role::LinksToEdit' => { table => 'work' };
with 'MusicBrainz::Server::Data::Role::Merge';

sub _table
{
    my $self = shift;
    return 'work ' . (shift() || '') . ' JOIN work_name name ON work.name=name.id';
}

sub _table_join_name {
    my ($self, $join_on) = @_;
    return $self->_table("ON work.name = $join_on");
}

sub _columns
{
    return 'work.id, work.gid, work.type AS type_id, name.name,
            work.iswc, work.comment, work.edits_pending, work.last_updated';
}

sub _id_column
{
    return 'work.id';
}

sub _gid_redirect_table
{
    return 'work_gid_redirect';
}

sub _entity_class
{
    return 'MusicBrainz::Server::Entity::Work';
}

sub find_by_artist
{
    my ($self, $artist_id, $limit, $offset) = @_;

    my $query =
        'SELECT link_type, ' . $self->_columns .'
           FROM (
                    -- Select works that are related to recordings for this artist
                    SELECT entity1 AS work, NULL as link_type
                      FROM l_recording_work
                      JOIN recording ON recording.id = entity0
                      JOIN artist_credit_name acn
                              ON acn.artist_credit = recording.artist_credit
                     WHERE acn.artist = ?
              UNION
                    -- Select works that this artist is related to
                    SELECT entity1 AS work, lt.name AS link_type
                      FROM l_artist_work ar
                      JOIN link ON ar.link = link.id
                      JOIN link_type lt ON lt.id = link.link_type
                     WHERE entity0 = ?
                ) s, ' . $self->_table .'
          WHERE work.id = s.work
       ORDER BY link_type NULLS FIRST, musicbrainz_collate(name.name)
         OFFSET ?';

    my (%grouped_works, %work_cache);

    # We actually use this for the side effect in the closure
    my (undef, $hits) = query_to_list_limited(
        $self->c->sql, $offset, $limit, sub {
            my $row = shift;

            my $work = $work_cache{ $row->{id} } || do {
                $work_cache{$row->{id}} = $self->_new_from_row($row);
            };

            my $group = $row->{link_type} || '';
            $grouped_works{$group} ||= [];
            push @{ $grouped_works{$group} }, $work;
        },
        $query, $artist_id, $artist_id, $offset || 0);

    return ([ map +{
        link_type => $_,
        works => $grouped_works{$_}
    }, sort keys %grouped_works ], $hits);
}

sub find_by_iswc
{
    my ($self, $iswc) = @_;
    my $query = "SELECT " . $self->_columns . "
                 FROM " . $self->_table . "
                 WHERE iswc = ?
                 ORDER BY musicbrainz_collate(name.name)";

    return query_to_list(
        $self->c->sql, sub { $self->_new_from_row(@_) },
        $query, $iswc);
}

sub load
{
    my ($self, @objs) = @_;
    load_subobjects($self, 'work', @objs);
}

sub insert
{
    my ($self, @works) = @_;
    my %names = $self->find_or_insert_names(map { $_->{name} } @works);
    my $class = $self->_entity_class;
    my @created;
    for my $work (@works)
    {
        my $row = $self->_hash_to_row($work, \%names);
        $row->{gid} = $work->{gid} || generate_gid();
        push @created, $class->new(
            id => $self->sql->insert_row('work', $row, 'id'),
            gid => $row->{gid}
        );
    }
    return @works > 1 ? @created : $created[0];
}

sub update
{
    my ($self, $work_id, $update) = @_;
    my %names = $self->find_or_insert_names($update->{name});
    my $row = $self->_hash_to_row($update, \%names);
    $self->sql->update_row('work', $row, { id => $work_id });
}

sub delete
{
    my ($self, $work_id) = @_;
    $self->c->model('Relationship')->delete_entities('work', $work_id);
    $self->annotation->delete($work_id);
    $self->alias->delete_entities($work_id);
    $self->tags->delete($work_id);
    $self->rating->delete($work_id);
    $self->remove_gid_redirects($work_id);
    $self->sql->do('DELETE FROM work WHERE id = ?', $work_id);
    return;
}

sub _merge_impl
{
    my ($self, $new_id, @old_ids) = @_;

    $self->alias->merge($new_id, @old_ids);
    $self->annotation->merge($new_id, @old_ids);
    $self->tags->merge($new_id, @old_ids);
    $self->rating->merge($new_id, @old_ids);
    $self->c->model('Edit')->merge_entities('work', $new_id, @old_ids);
    $self->c->model('Relationship')->merge_entities('work', $new_id, @old_ids);

    merge_table_attributes(
        $self->sql => (
            table => 'work',
            columns => [ qw( type iswc comment ) ],
            old_ids => \@old_ids,
            new_id => $new_id
        )
    );

    $self->_delete_and_redirect_gids('work', $new_id, @old_ids);
    return 1;
}

sub _hash_to_row
{
    my ($self, $work, $names) = @_;
    my $row = hash_to_row($work, {
        type => 'type_id',
        map { $_ => $_ } qw( iswc comment )
    });

    $row->{name} = $names->{$work->{name}}
        if (exists $work->{name});

    return $row;
}

sub load_meta
{
    my $self = shift;
    MusicBrainz::Server::Data::Utils::load_meta($self->c, "work_meta", sub {
        my ($obj, $row) = @_;
        $obj->rating($row->{rating} || 0);
        $obj->rating_count($row->{rating_count} || 0);
        $obj->last_updated($row->{last_updated}) if defined $row->{last_updated};
    }, @_);
}

=method load_ids

Load internal IDs for work objects that only have GIDs.

=cut

sub load_ids
{
    my ($self, @works) = @_;

    my @gids = map { $_->gid } @works;
    return () unless @gids;

    my $query = "
        SELECT gid, id FROM work
        WHERE gid IN (" . placeholders(@gids) . ")
    ";
    my %map = map { $_->[0] => $_->[1] }
        @{ $self->sql->select_list_of_lists($query, @gids) };

    for my $work (@works) {
        $work->id($map{$work->gid}) if exists $map{$work->gid};
    }
}

=method find_artists

This method will return a map with lists of artist names for the given
recordings. The names are taken both from the writers and recording artists.
This function is meant to be used to disambiguate works (e.g. in lookup
results).

=cut

sub find_artists
{
    my ($self, $works, $limit) = @_;

    my @ids = map { $_->id } @$works;
    return () unless @ids;

    my %map;
    $self->_find_writers(\@ids, \%map);
    $self->_find_recording_artists(\@ids, \%map);

    for my $work_id (keys %map)
    {
        my @artists = uniq map { $_->{entity}->name } @{ $map{$work_id} };
        $map{$work_id} = {
            hits => scalar @artists,
            results => $limit && scalar @artists > $limit ? [ @artists[ 0 .. ($limit-1) ] ] : \@artists,
        }
    }
    return %map;
}

=method load_writers

This method will load the work's writers based on the work-artist
relationships.

=cut

sub load_writers
{
    my ($self, @works) = @_;

    my @ids = map { $_->id } @works;
    return () unless @ids;

    my %map;
    $self->_find_writers(\@ids, \%map);
    for my $work (@works) {
        $work->add_writer(@{ $map{$work->id} })
            if exists $map{$work->id};
    }
}

sub _find_writers
{
    my ($self, $ids, $map) = @_;
    return unless @$ids;

    my $query = "
        SELECT law.entity1 AS work, law.entity0 AS artist, array_agg(lt.name) AS roles
        FROM l_artist_work law
        JOIN link l ON law.link = l.id
        JOIN link_type lt ON l.link_type = lt.id
        WHERE law.entity1 IN (" . placeholders(@$ids) . ")
        GROUP BY law.entity1, law.entity0
        ORDER BY count(*) DESC, artist
    ";

    my $rows = $self->sql->select_list_of_lists($query, @$ids); 

    my @artist_ids = map { $_->[1] } @$rows;
    my $artists = $self->c->model('Artist')->get_by_ids(@artist_ids);

    for my $row (@$rows) {
        my ($work_id, $artist_id, $roles) = @$row;
        $map->{$work_id} ||= [];
        push @{ $map->{$work_id} }, {
            entity => $artists->{$artist_id},
            roles => $roles
        }
    }
}

=method load_recording_artists

This method will load the work's artists based on the recordings the work
is linked to. The artist credits are sorted by the number of recordings in
descending order (i.e. the top artists will be first in the list).

=cut

sub load_recording_artists
{
    my ($self, @works) = @_;

    my @ids = map { $_->id } @works;
    return () unless @ids;

    my %map;
    $self->_find_recording_artists(\@ids, \%map);
    for my $work (@works) {
        $work->add_artist(map { $_->{entity} } @{ $map{$work->id} })
            if exists $map{$work->id};
    }
}

sub _find_recording_artists
{
    my ($self, $ids, $map) = @_;
    return unless @$ids;

    my $query = "
        SELECT lrw.entity1 AS work, r.artist_credit
        FROM l_recording_work lrw
        JOIN recording r ON lrw.entity0 = r.id
        WHERE lrw.entity1 IN (" . placeholders(@$ids) . ")
        GROUP BY lrw.entity1, r.artist_credit
        ORDER BY count(*) DESC, artist_credit
    ";

    my $rows = $self->sql->select_list_of_lists($query, @$ids); 

    my @artist_credit_ids = map { $_->[1] } @$rows;
    my $artist_credits = $self->c->model('ArtistCredit')->get_by_ids(@artist_credit_ids);

    my %work_acs = map { @$_ } @$rows;
    for my $work_id (keys %work_acs) {
        my $artist_credit_id = $work_acs{$work_id};
        $map->{$work_id} ||= [];
        push @{ $map->{$work_id} }, {
            entity => $artist_credits->{$artist_credit_id}
        }
    }
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;

=head1 COPYRIGHT

Copyright (C) 2009 Lukas Lalinsky

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

=cut
