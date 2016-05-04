package CommonTest;

use v5.16.3;
use Test::Roo::Role;
use Test::TempDir::Tiny;
use Path::Tiny;
use IPC::Cmd qw/can_run run run_forked/;

has workdir => (
    is      => 'ro',
    clearer => 1,
    lazy    => 1,
    default => sub { path(tempdir) },
);

has hsm_token_dir => (
    is      => 'ro',
    clearer => 1,
    lazy    => 1,
    default => sub {
        my $dir = $_[0]->workdir->child('tokens');
        $dir->mkpath;
        return $dir;
    },
);

has hsm_config => (
    is      => 'ro',
    default => sub {
        sprintf "directories.tokendir = %s\nobjectstore.backend = file",
          $_[0]->hsm_token_dir;
    },
);

has hsm_config_file => (
    is      => 'ro',
    lazy    => 1,
    clearer => 1,
    default => sub {
        my $self = shift;
        my $file = $self->workdir->child('softhsm2.conf');
        $file->spew($self->hsm_config);
        return $file;
    },
);

has key => (
    is      => 'ro',
    default => '',

);

has has_softhsm2 => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        return can_run('softhsm2-util');
    },
);

has _softhsm_util => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $p = can_run 'softhsm2-util';
        BAIL_OUT "softhsm2-util not found, cannot contiunue" unless $p;
        return path $p;
    },
);

has _openssl => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $p = can_run 'openssl';
        BAIL_OUT "openssl not found, cannot contiunue" unless $p;
        return path $p;
    },
);

sub BUILD {

    if ($ENV{TEST_DEBUG}) {
        require Log::Any::Adapter;
        Log::Any::Adapter->set('Stderr');
    }

    return;
}

has pkcs11 =>
  (is => 'rw', lazy => 1, builder => '_build_pkcs11', clearer => 1);

sub _build_pkcs11 {
    my $self = shift;
    my $mod  = 'Crypt::PKCS11::Easy';

    require_ok $mod;

    $ENV{SOFTHSM2_CONF} = $self->hsm_config_file;

    my $obj = new_ok $mod => [module => 'libsofthsm2'];

    BAIL_OUT "Failed to initialise $mod, no point continuing" unless $obj;

    return $obj;
}

sub _new_pkcs11 {
    my ($self, $key, $slot, $func) = @_;

    my $mod = 'Crypt::PKCS11::Easy';

    require_ok $mod;

    $ENV{SOFTHSM2_CONF} = $self->hsm_config_file;

    my $args = [module => 'libsofthsm2'];

    push @$args, key      => $key  if $key;
    push @$args, slot     => $slot if defined $slot;
    push @$args, function => $func if defined $func;
    push @$args, pin      => '1234';

    my $obj = new_ok $mod => $args;

    BAIL_OUT "Failed to initialise $mod, no point continuing" unless $obj;

    return $obj;
}

after each_test => sub { shift->clear_pkcs11 };

sub init_token {
    my ($self, $slot, $label) = @_;
    my @cmd = (
        $self->_softhsm_util, '--init-token', '--pin', '1234', '--so-pin',
        '123456', '--slot', $slot, '--label', $label
    );

    run
      command => \@cmd,
      verbose => $ENV{TEST_DEBUG},
      timeout => 10
      or die "Failed to initialise token";

    return;
}

sub import_key {
    my ($self, $slot, $key, $label) = @_;

    $key = path 't', 'keys', "$key.pkcs8";

    my @cmd = (
        $self->_softhsm_util, '--pin', '1234', '--slot', $slot, '--import',
        $key, '--label', $label, '--id', '0000'
    );

    run
      command => \@cmd,
      verbose => $ENV{TEST_DEBUG},
      timeout => 10
      or die "Failed to initialise token";

    return;
}

sub openssl_sign {
    my ($self, $key_file, $data_file) = @_;
    my $openssl_cmd = [$self->_openssl, 'dgst', '-sha1', '-sign', $key_file];
    my $output = run_forked $openssl_cmd,
      {verbose => $ENV{TEST_DEBUG}, child_stdin => $data_file->slurp_raw};
    chomp $output->{stdout};
    return $output->{stdout};
}

1;
