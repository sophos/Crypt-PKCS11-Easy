use lib 't/lib';
use Test::Roo;
use Test::Fatal;

use Path::Tiny;

with 'CommonTest';

test info => sub {
    my $self = shift;

    ok my $info = $self->pkcs11->get_info;
    isa_ok $info, 'HASH';
    is_deeply [sort keys %$info],
      [qw/cryptokiVersion libraryDescription libraryVersion manufacturerID/],
      'Keys are as expected';
    is $info->{manufacturerID}, 'SoftHSM', 'Correct manufacturerID';
};

test slots => sub {
    my $self = shift;

    ok my $slots = $self->pkcs11->get_slots;
    isa_ok $slots, 'ARRAY';
    is scalar @$slots, 1, 'softhsm always has at least one token';

    # this is done by softhsm
    $self->init_token(0, 'token_0');
    $self->import_key(0, '1024', 'test_key_1024');
    $self->clear_pkcs11;

    ok $slots = $self->pkcs11->get_slots;

    isa_ok $slots, 'ARRAY';
    is scalar @$slots, 2, 'There are now two tokens';

    like(
        exception { $self->pkcs11->get_slot(label => 'token_0') },
        qr/Missing id or token/,
        'Failed to find slot using invalid args',
    );

    like(
        exception { $self->pkcs11->get_slot(token => 'nosuchtoken') },
        qr/Unable to find slot containing token labelled/,
        'Failed to find slot using invalid args',
    );

    my $slot;
    is(
        exception { $slot = $self->pkcs11->get_slot(token => 'token_0') },
        undef, 'Found token by label',
    );

    my $slot2;
    is(
        exception { $slot2 = $self->pkcs11->get_slot(id => 0) },
        undef, 'Found token by id',
    );

    is_deeply $slot, $slot2, 'Slots are the same';
};

test get_mechs => sub {
    my $self = shift;

    my $mechs = $self->pkcs11->get_mechanisms(0);
    isa_ok $mechs, 'HASH';

};

my $sig;
test sign => sub {
    my $self = shift;

    my $data_file = path 't/data/10K.file';
    my $key_file  = path 't/keys/1024.pem';

    my $pkcs11 = $self->_new_pkcs11('test_key_1024', 0);

    ok $sig = $pkcs11->sign(file => $data_file);
    my $ossl_sig = $self->openssl_sign($key_file, $data_file);

    is $sig, $ossl_sig, 'Signing produced same sig as openssl';

    ok my $enc_sig = $pkcs11->sign_and_encode(file => $data_file);
    my $expectec_sig = q{-----BEGIN SIGNATURE-----
mjNMN4+Xf7PNsDGXjzyentTLSs1JI8G55Bbr+rBvHvDl9sOgFZTh9ZjTM1ekVcTN
mUwq3aC/GjFW+pOLRYevQ2UwJiZmcVtP4nDD9Vt/exZS/ggM4HnaoGm8QyGnhlk3
77J68o6bq2ilVIUxhTn2WzwZN/Se+5PuCCIomcy2OEY=
-----END SIGNATURE-----
};

    is $enc_sig, $expectec_sig, 'Encoded sigs are good';

};

test verify => sub {
    my $self = shift;

    my $data_file = path 't/data/10K.file';
    my $key_file  = path 't/keys/1024.pem';

    my $pkcs11 = $self->_new_pkcs11('test_key_1024', 0, 'verify');
    ok $pkcs11->verify(sig => $sig, file => $data_file);
};

run_me;
done_testing;
