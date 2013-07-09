package WebIrc::Client;

=head1 NAME

WebIrc::Client - Mojolicious controller for IRC chat

=cut

use Mojo::Base 'Mojolicious::Controller';
use constant DEBUG => $ENV{WIRC_DEBUG} ? 1 : 0;

my $N_MESSAGES = 50;

=head1 METHODS

=head2 route

Route to last seen IRC channel.

=cut

sub route {
  my $self = shift->render_later;
  my $uid  = $self->session('uid');
  my $settings = sub { $self->redirect_to($self->url_for('settings')) };

  if(!$uid) {
    $self->render('index');
  }
  else {
    Mojo::IOLoop->delay(
      sub {
        my($delay) = @_;
        $self->redis->get("user:$uid:cid_target", $delay->begin);
      },
      sub {
        my($delay, $cid_target) = @_;
        if(my($cid, $target) = $self->id_as($cid_target || '')) {
          $self->redis->del("user:$uid:cid_target"); # prevent loop on invalid cid_target
          $self->redirect_to($self->url_for('channel.view', cid => $cid, target => $target));
        }
        else {
          $self->redis->smembers("user:$uid:connections", $delay->begin);
        }
      },
      sub {
        my($delay, $connections) = @_;
        return $settings->() unless $connections->[0];
        $self->redis->smembers("connection:$connections->[0]:channels", $delay->begin);
        $delay->begin->(undef, $connections->[0]);
      },
      sub {
        my($delay, $channels, $cid) = @_;
        $self->redirect_to(
          $self->url_for('channel.view', cid => $cid, target => $channels->[0])
        );
      }
    );
  }
}

=head2 view

Used to render the main IRC client view.

=cut

sub view {
  my $self   = shift->render_later;
  my $redis  = $self->redis;
  my $uid    = $self->session('uid');
  my $cid    = $self->stash('cid');
  my $target = $self->stash('target') || '';
  my $key    = $target ? "connection:$cid:$target:msg" : "connection:$cid:msg";
  my $current_nick;

  Mojo::IOLoop->delay(
    $self->_check_if_uid_own_cid($cid),
    sub {
      my($delay) = @_;
      $redis->zrevrangebyscore("user:$uid:important_conversations", '+inf', '-inf', 'WITHSCORES', $delay->begin);
    },
    sub {
      my($delay, $important_conversations) = @_;
      my $n_notifications = 0;
      my $i = 0;

      while($i < @$important_conversations) {
        my($score) = splice @$important_conversations, ($i + 1), 1;
        $n_notifications += $score;
        $important_conversations->[$i] =~ /^(\d+):(.*)/;
        $important_conversations->[$i] = {
          cid => $1,
          id => $important_conversations->[$i],
          target => $2,
          score => $score,
        };
        $i++;
      }

      $self->stash(
        important_conversations => $important_conversations,
        n_notifications => $n_notifications,
      );

      $redis->hgetall("connection:$cid", $delay->begin);
      $redis->lrange("user:$uid:conversations", 0, -1, $delay->begin);
      $redis->set("user:$uid:cid_target", $self->as_id($cid, $target));
      $redis->del($target ? "connection:$cid:$target:unread" : "connection:$cid:unread");
    },
    sub {
      my($delay, $connection, $conversations) = @_;

      $self->stash(%$connection, conversations => $conversations);
      $redis->zcard($key, $delay->begin);

      for my $cid_target (@$conversations) {
        $cid_target =~ /^(\d+):(.*)/;
        $cid_target = { cid => $1, id => $cid_target, target => $2 };
      }
    },
    sub {
      my($delay, $length) = @_;
      my $end = $length > $N_MESSAGES ? $N_MESSAGES : $length;

      $redis->zrevrange($key => -$end, -1, $delay->begin);
    },
    sub {
      my($delay, $conversation) = @_;

      $self->format_conversation($conversation, $delay->begin);
    },
    sub {
      my($delay, $conversation) = @_;

      $self->stash(
        conversation => $conversation,
      );

      return $self->render('client/conversation', layout => undef) if $self->req->is_xhr;
      return $self->render;
    },
  );
}

=head2 connection_list

Will render the connection list for a given connection id.

=cut

sub connection_list {
  my $self = shift->render_later;
  my($cid, $target) = $self->id_as($self->stash('target'));

  $target ||= '';
  $self->stash(target => $target, cid => $cid);
  Mojo::IOLoop->delay(
    $self->_check_if_uid_own_cid($cid),
    sub {
      my($delay) = @_;
      $self->redis->hmget("connection:$cid" => qw/ nick host /, $delay->begin);
    },
    sub {
      my($delay, $connection) = @_;
      $self->_fetch_conversation_lists(
        $delay,
        {
          cid => $cid,
          host => $connection->[1],
          nick => $connection->[0],
        },
      );
    },
    sub {
      my($delay, $connection) = @_;
      $self->render('client/connection_list', %$connection);
    },
  );
}

=head2 history

Used to render the previous messages in a conversation, suitable for the IRC
client view.

=cut

sub history {
  my $self = shift->render_later;
  my $offset = $self->stash('offset');
  my($cid, $target) = $self->id_as($self->stash('target'));
  my $key = $target ? "connection:$cid:$target:msg" : "connection:$cid:msg";

  unless($offset and $cid) {
    return $self->render_exception('Missing parameters'); # TODO: Need to have a better error message?
  }

  $target ||= '';
  $self->stash(target => $target, cid => $cid, nick => '', nicks => []);
  Mojo::IOLoop->delay(
    $self->_check_if_uid_own_cid($cid),
    sub {
      my($delay) = @_;
      $self->redis->zrevrangebyscore($key => $offset, '-inf', limit => 0 => $N_MESSAGES, $delay->begin);
    },
    sub {
      my($delay, $conversation) = @_;
      $self->format_conversation($conversation, $delay->begin);
    },
    sub {
      my($delay, $conversation) = @_;
      $self->render('client/conversation', conversation => $conversation);
    },
  );
}

sub _check_if_uid_own_cid {
  my($self, $cid) = @_;
  my $uid = $self->session('uid') // -1;

  sub {
    my($delay) = @_;
    $self->redis->sismember("user:$uid:connections", $cid, $delay->begin);
  },
  sub {
    my($delay, $is_owner) = @_;
    return $delay->begin->() if $is_owner;
    $self->redis->del("user:$uid:cid_target");
    $self->route;
  },
}

sub _fetch_conversation_lists {
  my($self, $delay, @connections) = @_;

  for my $info (@connections) {
    my $cid = $info->{cid};
    my $cb = $delay->begin;
    $self->redis->execute(
      [ smembers => "connection:$cid:channels" ],
      [ smembers => "connection:$cid:conversations" ],
      sub {
        my ($redis, $channels, $conversations) = @_;
        my @unread = map { [get => "connection:$cid:$_:unread"] } sort(@$channels), sort(@$conversations);

        $info->{channels} = $channels;
        $info->{conversations} = $conversations;
        $info->{unread} = [];

        return $cb->(undef, $info) unless @unread;
        return $redis->execute(@unread, sub {
          my $redis = shift;
          push @{ $info->{unread} }, @_;
          $cb->(undef, $info);
        });
      },
    );
  }
}

=head1 COPYRIGHT

See L<WebIrc>.

=head1 AUTHOR

Jan Henning Thorsen

Marcus Ramberg

=cut

1;
