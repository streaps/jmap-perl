#!/usr/bin/perl -cw

use strict;
use warnings;

package JMAP::DB;

use Data::Dumper;
use DBI;
use Carp qw(confess);

use JSON::XS qw(encode_json decode_json);
use Email::MIME;
# seriously, it's parsable, get over it
$Email::MIME::ContentType::STRICT_PARAMS = 0;
use HTML::Strip;
use Image::Size;
use Email::Address;
use Encode;
use Encode::MIME::Header;
use DateTime;
use Date::Parse;

sub new {
  my $class = shift;
  my $accountid = shift || die;
  my $dbh = DBI->connect("dbi:SQLite:dbname=/home/jmap/data/$accountid.sqlite3");
  my $Self = bless { accountid => $accountid, dbh => $dbh, start => time() }, ref($class) || $class;
  $Self->_initdb($dbh);
  return $Self;
}

sub delete {
  my $Self = shift;
  my $accountid = $Self->accountid();
  delete $Self->{dbh};
  unlink("/home/jmap/data/$accountid.sqlite3");
}

sub accountid {
  my $Self = shift;
  return $Self->{accountid};
}

sub log {
  my $Self = shift;
  if ($Self->{logger}) {
    $Self->{logger}->(@_);
  }
  else {
    my ($level, @items) = @_;
    return if $level eq 'debug';
    my $time = time() - $Self->{start};
    warn "[$level $time]: @items\n";
  }
}

sub dbh {
  my $Self = shift;
  return $Self->{dbh};
}

sub begin {
  my $Self = shift;
  confess("ALREADY IN TRANSACTION") if $Self->{t};
  $Self->dbh->begin_work();
  $Self->{t} = {};
}

sub commit {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};
  $Self->dbh->commit();
  my $t = delete $Self->{t};

  # push an update if anything to tell..
  if ($t->{modseq} and $Self->{change_cb}) {
    $Self->{change_cb}->($Self, "$t->{modseq}"); # aka stateString
  }
}

sub rollback {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};
  $Self->dbh->rollback();
  delete $Self->{t};
}

# handy for error cases
sub reset {
  my $Self = shift;
  return unless $Self->{t};
  $Self->dbh->rollback();
  delete $Self->{t};
}

sub dirty {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};
  unless ($Self->{t}{modseq}) {
    my $user = $Self->get_user();
    $user->{jhighestmodseq}++;
    $Self->dbh->do("UPDATE account SET jhighestmodseq = ?", {}, $user->{jhighestmodseq});
    $Self->{t}{modseq} = $user->{jhighestmodseq};
    $Self->log('debug', "dirty at $user->{jhighestmodseq}");
  }
  return $Self->{t}{modseq};
}

sub get_user {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};
  unless ($Self->{t}{user}) {
    $Self->{t}{user} = $Self->dbh->selectrow_hashref("SELECT email,displayname,picture,jhighestmodseq,jdeletedmodseq FROM account");
  }
  # bootstrap
  unless ($Self->{t}{user}) {
    my $data = {
      jhighestmodseq => 1,
    };
    $Self->dinsert('account', $data);
    $Self->{t}{user} = $data;
  }
  return $Self->{t}{user};
}

sub get_mailboxes {
  my $Self = shift;
  confess("NOT IN TRANSACTION") unless $Self->{t};
  unless ($Self->{t}{mailboxes}) {
    $Self->{t}{mailboxes} = $Self->dbh->selectall_hashref("SELECT jmailboxid, jmodseq, label, name, parentid, nummessages, numumessages, numthreads, numuthreads, active FROM jmailboxes", 'jmailboxid', {Slice => {}});
  }
  return $Self->{t}{mailboxes};
}

sub get_mailbox {
  my $Self = shift;
  my $jmailboxid = shift;
  return $Self->get_mailboxes->{$jmailboxid};
}

sub add_mailbox {
  my $Self = shift;
  my ($name, $label, $parentid) = @_;

  my $mailboxes = $Self->get_mailboxes();

  confess("ALREADY EXISTS $name in $parentid") if grep { $_->{name} eq $name and $_->{parentid} == $parentid } values %$mailboxes;

  my $data = {
    name => $name,
    label => $label,
    parentid => $parentid,
    nummessages => 0,
    numthreads => 0,
    numumessages => 0,
    numuthreads => 0,
    active => 1,
  };

  my $id = $data->{jmailboxid} = $Self->dinsert('jmailboxes', $data);
  $Self->{t}{mailboxes}{$id} = $data;

  return $id;
}

sub update_mailbox {
  my $Self = shift;
  my $jmailboxid = shift;
  my $fields = shift;

  my $mailbox = $Self->get_mailbox($jmailboxid);
  confess("INVALID ID $jmailboxid") unless $mailbox;
  confess("NOT ACTIVE $jmailboxid") unless $mailbox->{active};

  foreach my $key (keys %$fields) {
    $mailbox->{$key} = $fields->{$key};
  }

  unless ($mailbox->{active}) {
    # XXX - sanity check all?
    confess("Still messages") if $mailbox->{nummessages};
  }

  $Self->dmaybedirty('jmailboxes', $mailbox, {jmailboxid => $jmailboxid});
}

sub delete_mailbox {
  my $Self = shift;
  my $jmailboxid = shift;
  return $Self->update_mailbox($jmailboxid, {active => 0});
}

sub add_message {
  my $Self = shift;
  my ($data, $mailboxes) = @_;

  return unless @$mailboxes; # no mailboxes, no message

  $Self->dmake('jmessages', $data, $Self->{backfilling});
  foreach my $mailbox (@$mailboxes) {
    $Self->add_message_to_mailbox($data->{msgid}, $mailbox);
  }
}

sub add_message_to_mailbox {
  my $Self = shift;
  my ($msgid, $jmailboxid) = @_;

  my $data = {msgid => $msgid, jmailboxid => $jmailboxid};
  $Self->dmake('jmessagemap', $data);
  $Self->dmaybeupdate('jmailboxes', {jcountsmodseq => $data->{jmodseq}}, {jmailboxid => $jmailboxid});
}

sub get_raw_message {
  my $Self = shift;
  my $rfc822 = shift;
  my $part = shift;

  return ('message/rfc822', $rfc822) unless $part;

  my $eml = Email::MIME->new($rfc822);
  return find_part($eml, $part);
}

sub add_raw_message {
  my $Self = shift;
  my $msgid = shift;
  my $rfc822 = shift;

  my $eml = Email::MIME->new($rfc822);
  my $message = $Self->parse_message($msgid, $eml);

  # fiddle the top-level fields
  my $data = {
    msgid => $msgid,
    rfc822 => $rfc822,
    parsed => encode_json($message),
  };

  $Self->dinsert('jrawmessage', $data);

  return $message;
}

sub parse_date {
  my $Self = shift;
  my $date = shift;
  return str2time($date);
}

sub isodate {
  my $Selft = shift;
  my $epoch = shift;
  return unless $epoch; # no 1970, punk

  my $date = DateTime->from_epoch( epoch => $epoch );
  return $date->iso8601();
}

sub parse_emails {
  my $Self = shift;
  my $emails = shift;

  my @addrs = eval { Email::Address->parse($emails) };
  return map { { name => Encode::decode_utf8($_->name()), email => $_->address() } } @addrs;
}

sub parse_message {
  my $Self = shift;
  my $messageid = shift;
  my $eml = shift;
  my $part = shift;

  my $preview = preview($eml);
  my $textpart = textpart($eml);
  my $htmlpart = htmlpart($eml);

  my $hasatt = hasatt($eml);
  my $headers = headers($eml);
  my $messages = {};
  my @attachments = $Self->attachments($messageid, $eml, $part, $messages);

  my $data = {
    to => [$Self->parse_emails($eml->header('To'))],
    cc => [$Self->parse_emails($eml->header('Cc'))],
    bcc => [$Self->parse_emails($eml->header('Bcc'))],
    from => [$Self->parse_emails($eml->header('From'))]->[0],
    replyTo => [$Self->parse_emails($eml->header('Reply-To'))]->[0],
    subject => decode('MIME-Header', $eml->header('Subject')),
    date => $Self->isodate($Self->parse_date($eml->header('Date'))),
    preview => $preview,
    textBody => $textpart,
    htmlBody => $htmlpart,
    hasAttachment => $hasatt,
    headers => $headers,
    attachments => \@attachments,
    attachedMessages => $messages,
  };

  return $data;
}

sub headers {
  my $eml = shift;
  my $obj = $eml->header_obj();
  my %data;
  foreach my $name ($obj->header_names()) {
    my @values = $obj->header($name);
    $data{$name} = join("\n", @values);
  }
  return \%data;
}

sub find_part {
  my $eml = shift;
  my $target = shift;
  my $part = shift;
  my $num = 0;
  foreach my $sub ($eml->subparts()) {
    $num++;
    my $id = $part ? "$part.$num" : $num;
    my $type = $sub->content_type();
    $type =~ s/;.*//;
    return ($type, $sub->body()) if ($id eq $target);
    if ($type =~ m{^multipart/}) {
      my @res = find_part($sub, $id);
      return @res if @res;
    }
  }
  return ();
}

sub attachments {
  my $Self = shift;
  my $messageid = shift;
  my $eml = shift;
  my $part = shift;
  my $messages = shift;
  my $num = 0;
  my @res;
  foreach my $sub ($eml->subparts()) {
    $num++;
    my $type = $sub->content_type();
    next unless $type;
    my $disposition = $sub->header('Content-Disposition') || 'inline';
    my ($typerest, $disrest) = ('', '');
    if ($type =~ s/;(.*)//) {
      $typerest = $1;
    }
    if ($disposition =~ s/;(.*)//) {
      $disrest = $1;
    }
    my $filename = "unknown";
    if ($disrest =~ m{filename=([^;]+)} || $typerest =~ m{name=([^;]+)}) {
      $filename = $1;
      if ($filename =~ s/^([\'\"])//) {
        $filename =~ s/$1$//;
      }
    }
    my $isInline = $disposition eq 'inline';
    if ($isInline) {
      # these parts, inline, are not attachments
      next if $type =~ m{^text/plain}i;
      next if $type =~ m{^text/html}i;
    }
    my $id = $part ? "$part.$num" : $num;
    if ($type =~ m{^message/rfc822}i) {
      $messages->{$id} = $Self->parse_message($messageid, $sub, $id);
    }
    elsif ($sub->subparts) {
      push @res, $Self->attachments($messageid, $sub, $id, $messages);
      next;
    }
    my $headers = headers($sub);
    my $body = $sub->body();
    my %extra;
    if ($type =~ m{^image/}) {
      my ($w, $h) = imgsize(\$body);
      $extra{width} = $w;
      $extra{height} = $h;
    }
    my $accountid = $Self->accountid();
    push @res, {
      id => $id,
      type => $type,
      url => "https://proxy.jmap.io/raw/$accountid/$messageid/$id/$filename",
      name => $filename,
      size => length($body),
      isInline => $isInline,
      %extra,
    };
  }
  return @res;
}

sub _clean {
  my ($type, $text) = @_;
  #if ($type =~ m/;\s*charset\s*=\s*([^;]+)/) {
    #$text = Encode::decode($1, $text);
  #}
  return $text;
}

sub textpart {
  my $eml = shift;
  my $type = $eml->content_type() || 'text/plain';
  if ($type =~ m{^text/plain}i) {
    return _clean($type, $eml->body_str());
  }
  foreach my $sub ($eml->subparts()) {
    my $res = textpart($sub);
    return $res if $res;
  }
  return undef;
}

sub htmlpart {
  my $eml = shift;
  my $type = $eml->content_type() || 'text/plain';
  if ($type =~ m{^text/html}i) {
    return _clean($type, $eml->body_str());
  }
  foreach my $sub ($eml->subparts()) {
    my $res = htmlpart($sub);
    return $res if $res;
  }
  return undef;
}

sub htmltotext {
  my $html = shift;
  my $hs = HTML::Strip->new();
  my $clean_text = $hs->parse( $html );
  $hs->eof;
  return $clean_text;
}

sub preview {
  my $eml = shift;
  my $type = $eml->content_type() || 'text/plain';
  if ($type =~ m{text/plain}i) {
    my $text = _clean($type, $eml->body_str());
    return make_preview($text);
  }
  if ($type =~ m{text/html}i) {
    my $text = _clean($type, $eml->body_str());
    return make_preview(htmltotext($text));
  }
  foreach my $sub ($eml->subparts()) {
    my $res = preview($sub);
    return $res if $res;
  }
  return undef;
}

sub make_preview {
  my $text = shift;
  $text =~ s/\s+/ /gs;
  return substr($text, 0, 256);
}

sub hasatt {
  my $eml = shift;
  my $type = $eml->content_type() || 'text/plain';
  return 1 if $type =~ m{(image|video|application)/};
  foreach my $sub ($eml->subparts()) {
    my $res = hasatt($sub);
    return $res if $res;
  }
  return 0;
}

sub delete_message_from_mailbox {
  my $Self = shift;
  my ($msgid, $jmailboxid) = @_;

  my $data = {active => 0};
  $Self->ddirty('jmessagemap', $data, {msgid => $msgid, jmailboxid => $jmailboxid});
  $Self->dmaybeupdate('jmailboxes', {jcountsmodseq => $data->{jmodseq}}, {jmailboxid => $jmailboxid});
}

sub change_message {
  my $Self = shift;
  my ($msgid, $data, $newids) = @_;

  # doesn't work if only IDs have changed :( 
  #return unless $Self->dmaybedirty('jmessages', $data, {msgid => $msgid});

  $Self->ddirty('jmessages', $data, {msgid => $msgid});

  my $oldids = $Self->dbh->selectcol_arrayref("SELECT jmailboxid FROM jmessagemap WHERE msgid = ? AND active = 1", {}, $msgid);
  my %old = map { $_ => 1 } @$oldids;

  foreach my $jmailboxid (@$newids) {
    if (delete $old{$jmailboxid}) {
      # just bump the modseq
      $Self->dmaybeupdate('jmailboxes', {jcountsmodseq => $data->{jmodseq}}, {jmailboxid => $jmailboxid});
    }
    else {
      $Self->add_message_to_mailbox($msgid, $jmailboxid);
    }
  }

  foreach my $jmailboxid (keys %old) {
    $Self->delete_message_from_mailbox($msgid, $jmailboxid);
  }
}

sub update_messages {
  my $Self = shift;
  die "Virtual method";
}

sub delete_message {
  my $Self = shift;
  my ($msgid) = @_;

  return $Self->change_message($msgid, {active => 0}, []);
}

sub create_file {
  my $Self = shift;
  my $type = shift;
  my $content = shift;
  my $expires = shift // time() + (7 * 86400);

  my $size = length($content);

  # XXX - no dedup on sha1 here yet
  my $id = $self->dinsert('jfiles', { type => $type, size => $size, content => $content, expires => $expires });

  return {
    id => $id,
    type => $type,
    expires => $expires,
    size => $size,
  };
}

sub _dbl {
  return '(' . join(', ', map { defined $_ ? "'$_'" : 'NULL' } @_) . ')';
}

sub dinsert {
  my $Self = shift;
  my ($table, $values) = @_;

  confess("NOT IN TRANSACTION") unless $Self->{t};

  $values->{mtime} = time();

  my @keys = sort keys %$values;
  my $sql = "INSERT OR REPLACE INTO $table (" . join(', ', @keys) . ") VALUES (" . join (', ', map { "?" } @keys) . ")";

  $Self->log('debug', $sql, _dbl( map { $values->{$_} } @keys));

  $Self->dbh->do($sql, {}, map { $values->{$_} } @keys);

  my $id = $Self->dbh->last_insert_id(undef, undef, undef, undef);
  return $id;
}

# dinsert with a modseq
sub dmake {
  my $Self = shift;
  my ($table, $values, $backfilling) = @_;
  $values->{jmodseq} = $backfilling ? 1 : $Self->dirty();
  $values->{active} = 1;
  return $Self->dinsert($table, $values);
}

sub dupdate {
  my $Self = shift;
  my ($table, $values, $limit) = @_;

  confess("NOT IN TRANSACTION") unless $Self->{t};

  $values->{mtime} = time();

  my @keys = sort keys %$values;
  my @lkeys = sort keys %$limit;

  my $sql = "UPDATE $table SET " . join (', ', map { "$_ = ?" } @keys) . " WHERE " . join(' AND ', map { "$_ = ?" } @lkeys);

  $Self->log('debug', $sql, _dbl(map { $values->{$_} } @keys), _dbl(map { $limit->{$_} } @lkeys));

  $Self->dbh->do($sql, {}, (map { $values->{$_} } @keys), (map { $limit->{$_} } @lkeys));
}

sub filter_values {
  my $Self = shift;
  my ($table, $values, $limit) = @_;

  # copy so we don't edit the original
  my %values = %$values;

  my @keys = sort keys %$values;
  my @lkeys = sort keys %$limit;

  my $sql = "SELECT " . join(', ', @keys) . " FROM $table WHERE " . join(' AND ', map { "$_ = ?" } @lkeys);
  my $data = $Self->dbh->selectrow_hashref($sql, {}, map { $limit->{$_} } @lkeys);
  foreach my $key (@keys) {
    delete $values{$key} if $limit->{$key}; # in the limit, no point setting again
    delete $values{$key} if ($data->{$key} || '') eq ($values{$key} || '');
  }

  return \%values;
}

sub dmaybeupdate {
  my $Self = shift;
  my ($table, $values, $limit) = @_;

  my $filtered = $Self->filter_values($table, $values, $limit);
  return unless %$filtered;

  return $Self->dupdate($table, $filtered, $limit);
}

# dupdate with a modseq
sub ddirty {
  my $Self = shift;
  my ($table, $values, $limit) = @_;
  $values->{jmodseq} = $Self->dirty();
  return $Self->dupdate($table, $values, $limit);
}

sub dmaybedirty {
  my $Self = shift;
  my ($table, $values, $limit) = @_;

  my $filtered = $Self->filter_values($table, $values, $limit);
  return unless %$filtered;

  $filtered->{jmodseq} = $values->{jmodseq} = $Self->dirty();
  return $Self->dupdate($table, $filtered, $limit);
}

sub ddelete {
  my $Self = shift;
  my ($table, $limit) = @_;

  confess("NOT IN TRANSACTION") unless $Self->{t};

  my @lkeys = sort keys %$limit;
  my $sql = "DELETE FROM $table WHERE " . join(' AND ', map { "$_ = ?" } @lkeys);

  $Self->log('debug', $sql, _dbl(map { $limit->{$_} } @lkeys));

  $Self->dbh->do($sql, {}, map { $limit->{$_} } @lkeys);
}

sub _initdb {
  my $Self = shift;
  my $dbh = shift;

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jmessages (
  msgid TEXT PRIMARY KEY,
  thrid TEXT,
  internaldate INTEGER,
  sha1 TEXT,
  isUnread BOOLEAN,
  isFlagged BOOLEAN,
  isAnswered BOOLEAN,
  isDraft BOOLEAN,
  msgfrom TEXT,
  msgto TEXT,
  msgcc TEXT,
  msgbcc TEXT,
  msgsubject TEXT,
  msginreplyto TEXT,
  msgmessageid TEXT,
  msgdate INTEGER,
  msgsize INTEGER,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS jthrid ON jmessages (thrid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jmailboxes (
  jmailboxid INTEGER PRIMARY KEY,
  parentid INTEGER,
  role TEXT,
  name TEXT,
  precedence INTEGER,
  mustBeOnly BOOLEAN,
  mayDelete BOOLEAN,
  mayRename BOOLEAN,
  mayAdd BOOLEAN,
  mayRemove BOOLEAN,
  mayChild BOOLEAN,
  mayRead BOOLEAN,
  jmodseq INTEGER,
  jcountsmodseq INTEGER,
  mtime DATE,
  active BOOLEAN
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jmessagemap (
  jmailboxid INTEGER,
  msgid TEXT,
  jmodseq INTEGER,
  mtime DATE,
  active BOOLEAN,
  PRIMARY KEY (jmailboxid, msgid)
);
EOF

  $dbh->do("CREATE INDEX IF NOT EXISTS msgidmap ON jmessagemap (msgid)");

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS account (
  email TEXT,
  displayname TEXT,
  picture TEXT,
  jdeletedmodseq INTEGER,
  jhighestmodseq INTEGER,
  mtime DATE
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jrawmessage (
  msgid TEXT PRIMARY KEY,
  rfc822 TEXT,
  parsed TEXT,
  mtime DATE
);
EOF

  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS jfiles (
  jfileid INTEGER PRIMARY KEY,
  type TEXT,
  size INTEGER,
  content TEXT,
  expires DATE,
  mtime DATE,
  active BOOLEAN
);
EOF

}

1;