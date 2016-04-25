use Test::More;
use Test::Fatal;

use Crypt::PKCS11::Easy;

delete $ENV{SOFTHSM2_CONF};

like(
    exception { Crypt::PKCS11::Easy->new },
    qr/Missing required arguments: module/,
    'Died without module',
);

like(
    exception { Crypt::PKCS11::Easy->new(module => 'nosuchmodule') },
    qr/Unable to find .+nosuchmodule/,
    'Died with an invalid module',
);

like(
    exception { Crypt::PKCS11::Easy->new(module => 'libsofthsm2') },
    qr/Failed to initialize PKCS11 module/,
    'Module is not configured',
);

done_testing;
