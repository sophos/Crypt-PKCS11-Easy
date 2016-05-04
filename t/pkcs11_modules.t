use lib 't/lib';
use Path::Tiny;
use Test::Roo;
use Test::Fatal;

test module => sub {
    my $self = shift;

    my $mod = 'Crypt::PKCS11::Easy';
    require_ok $mod;

    # this is an empty file, so can never be loaded
    like(
        exception { $mod->new(module => 't/lib/fakemodule.so') },
        qr/^Failed to load PKCS11 module \[.+\/t\/lib\/fakemodule.so\]: CKR_FUNCTION_FAILED/,
        'Attempted to load module from full path',
    );

    # this will load but fail to initialize without valid config
    local $ENV{SOFTHSM2_CONF} = undef;
    like(
        exception { $mod->new(module => 'libsofthsm2') },
        qr/^Failed to initialize PKCS11 module \[.+libsofthsm2.so\]: CKR_GENERAL_ERROR/,
        'Attempted to load module from name only',
    );

};

run_me;
done_testing;
