# NAME

Crypt::PKCS11::Easy - Wrapper around Crypt::PKCS11 to make using a HSM not suck

# VERSION

version 0.161750

# SYNOPSIS

    use Crypt::PKCS11::Easy;
    use IO::Prompter;

    my $file = '/file/to/sign';

    my $hsm = Crypt::PKCS11::Easy->new(
        module => 'libCryptoki2_64',
        key    => 'MySigningKey',
        slot   => '0',
        pin    => sub { prompt 'Enter PIN: ', -echo=>'*' },
    );

    my $base64_signature = $hsm->sign_and_encode(file => $file);
    my $binary_signature = $hsm->decode_signature(data => $base64_signature);

    $hsm->verify(file => $data_file, sig => $binary_signature)
      or die "VERIFICATION FAILED\n";

# DESCRIPTION

This module is an OO wrapper around [Crypt::PKCS11](https://metacpan.org/pod/Crypt::PKCS11), designed primarily to make
using a HSM as simple as possible.

## Signing a file with `Crypt::PKCS11`

    use IO::Prompter;
    use Crypt::PKCS11;
    use Crypt::PKCS11::Attributes;

    my $pkcs11 = Crypt::PKCS11->new;
    $pkcs11->load('/usr/safenet/lunaclient/lib/libCryptoki2_64.so');
    $pkcs11->Initialize;
    # assuming there is only one slot
    my @slot_ids = $pkcs11->GetSlotList(1);
    my $slot_id = shift @slot_ids;

    my $session = $pkcs11->OpenSession($slot_id, CKF_SERIAL_SESSION)
        or die "Error" . $pkcs11->errstr;

    $session->Login(CKU_USER, sub { prompt 'Enter PIN: ', -echo=>'*' } )
        or die "Failed to login: " . $session->errstr;

    my $object_template = Crypt::PKCS11::Attributes->new->push(
        Crypt::PKCS11::Attribute::Label->new->set('MySigningKey'),
        Crypt::PKCS11::Attribute::Sign->new->set(1),
    );
    $session->FindObjectsInit($object_template);
    my $objects = $session->FindObjects(1);
    my $key = shift @$objects;

    my $sign_mech = Crypt::PKCS11::CK_MECHANISM->new;
    $sign_mech->set_mechanism(CKM_SHA1_RSA_PKCS);

    $session->SignInit($sign_mech, $key)
        or die "Failed to set init signing: " . $session->errstr;

    my $sig = $session->Sign('SIGN ME')
        or die "Failed to sign: " . $session->errstr;

## Signing a file with `Crypt::PKCS11::Easy`

    use Crypt::PKCS11::Easy;
    use IO::Prompter;

    my $hsm = Crypt::PKCS11::Easy->new(
        module => 'libCryptoki2_64',
        key    => 'MySigningKey',
        slot   => '0',
        pin    => sub { prompt 'Enter PIN: ', -echo=>'*' },
    );

    my $sig = $hsm->sign(data => 'SIGN ME');

To make that conciseness possible a `Crypt::PKCS11::Object` can only be used
for one function, e.g. signing OR verifying, and cannot be set to use a
different key or a different token after instantiation. A new object should be
created for each function.

# ATTRIBUTES

## `module`

String. Required.

The name of the PKCS#11 module to use. Either pass the full path to the module,
or just pass the base name of the library and the rest will be handled
automagically. e.g.

    libsofthsm2          => /usr/lib64/pkcs11/libsofthsm2.so
    libCryptoki2_64      => /usr/lib64/pkcs11/libCryptoki2_64.so
    gnome-keyring-pkcs11 => /usr/lib64/pkcs11/gnome-keyring-pkcs11.so

## `rw`

Boolean. Controls whether a session will be opened in Read/Write mode or not.
Defaults to off. Writing is only needed to make modifications to a token or the
objects on it.

## `key`

String. The label of the you want to use.

## `function`

String. The function that will be performed with this object. Can be 'sign' or
'verify'. Defaults to 'sign'. It affects how the key can be used. If function is
sign and you try to verify a signature, the underlying library will return an
error.

## `slot`

Integer. The id number of the slot to use.

## `token`

String. Instead of specifying the ["slot"](#slot), find and use the slot that contains
a token with this label.

## `pin`

String, Coderef or [Path::Tiny](https://metacpan.org/pod/Path::Tiny) object. This is either the PIN/password required
to access a token, a coderef that returns it, or a file that contains it.

    use IO::Prompter;
    $pin = sub { prompt 'Enter PIN: ', -echo=>'*' };

    use Path::Tiny;
    $pin = path '/secure/file/with/password'

    $pin = '1234';

## `module_dirs`

Array of paths to check for PKCS#11 modules.

# METHODS

## `get_info`

Returns a hashref containing basic info about the PKCS#11 implementation,
currently the manufacturer, library description and Cryptoki version that is
implemented.

## `get_token_info(Int $slot_id)`

Returns a hashref containing details on the token in slot identified by
`$slot_id`.

## `get_slot(id =` $int | token => $string)>

Returns a hashref containing details on the slot identified by `$id` **OR** the
slot which contains a `token` with the label `$string`. If a token is present
in the slot, its details will also be retrieved.

    my $slot = $pkcs11->get_slot(id => 1);

    my $slot = $pkcs11->get_slot(token => 'Build Signer');
    say $slot->{token}->{serialNumber};

## `get_slots(Bool $with_token?)`

Returns an arrayref of all visible slots. Each element in the array will
be a hashref returned by ["get\_slot"](#get_slot).

If `$with_token` is true then only slots that contain a token will be returned.

## `login`

Attempts to login to the HSM. In most use cases, this will be handled
automatically when needed.

## `get_signing_key(Str $label)`

Will look for a key matching with a label matching `$label` which can be used
for signing.

The returned key is a [Crypt::PKCS11::Object](https://metacpan.org/pod/Crypt::PKCS11::Object).

## `get_verification_key(Str $label)`

Will look for a key matching with a label matching `$label` which can be used
for signature verification.

The returned key is a [Crypt::PKCS11::Object](https://metacpan.org/pod/Crypt::PKCS11::Object).

## `sign((data =` 'some data' | file => '/path'), mech => 'RSA\_PKCS'?)>

Returns a binary signature. The data to be signed is either passed as a scalar
in `data`, or in `file` which can be a string path or a [Path::Tiny](https://metacpan.org/pod/Path::Tiny) object.

A PKCS#11 mechanism can optionally be specified as a string and without the
leading 'CKM\_'.

    my $sig = $hsm->sign(file => $file, mech => 'RSA_PKCS');
    my $sig = $hsm->sign(data => 'SIGN ME');

## `sign_and_encode(...)`

Wrapper around ["sign"](#sign) which will return the signature data as base64 PEM, e.g.

    -----BEGIN SIGNATURE-----
    YHXMbvdWyUXeNvgfMzQA+9FjytOWPZCik/H3GS6t72xtk1gvHNfQpKdURKvgBeJM
    QdUJ7ceujzGX5v/UJRJ4oSpLLiptn2BYaeAn/gUg7yKDFg4YuVN7RU7MbrN2jjlw
    RfKHq6h6G4FP8LJz5jQWlKKIPoiJ2g3a9M7dq0+hG/kPOv4pBLm7G30uaiSpi/3O
    hhV+aw87HB7H7i09NSIHoWRxXqw8BeFse7jWTjbj5X1j9uNxD+W6+sxyERawfqFP
    3WuzDIcD8kgMA7cM7a6z+h1bEgUt2FUKGytcTX4ymAz9+aS+u24V81mg0Ia3pZQd
    Pth2532FY0z+Ajn3GojNVw==
    -----END SIGNATURE-----

## `verify((data =` 'some data' | file => '/path'), sig => $sig, mech => 'RSA\_PKCS'?)>

Verifies a signature. Parameters are the same as ["sign"](#sign), and also requires
a binary signature. Returns true or false.

    $hsm->verify(file => $file_to_check, sig => $binary_sig, mech => 'RSA_PKCS')
        or die "Signature verification failed!\n";

## `digest((data =` 'some data' | file => '/path'), mech => 'SHA\_1'?)>

Returns a binary digest. Parameters are the same as ["sign"](#sign).

    $hsm->digest(file => $file_to_check, mech => 'RSA_PKCS')

## `decode_signature((data =` 'some data' | file => '/path'))>

Verifies a signature. Parameters are the same as ["sign"](#sign), and also requires
a binary signature. Returns true or false.

    $hsm->verify(file => $file_to_check, sig => $binary_sig, mech => 'RSA_PKCS')
        or die "Signature verification failed!\n";

## `get_mechanism_info($mech, $slot_id?)`

Will return a details of a mechanism as a hashref. If a slot id is specifed, the
mechanisms for that slot will be retrieved. Otherwise, the slot id in ["slot"](#slot)
 will be used if there is one.

## `get_mechanisms($slot_id?)`

Will return a hashref of available mechanisms. If a slot id is specifed, the
mechanisms for that slot will be retrieved. Otherwise, the slot id in ["slot"](#slot)
 will be used if there is one.

# STATUS

# DIAGNOSTICS

`Crypt::PKCS11::Easy` uses [Log::Any](https://metacpan.org/pod/Log::Any) for logging. To see debug output on
`STDOUT`, for example, in your application use:

    use Log::Any::Adapter 'Stdout', log_level => 'debug';

# ERRORS

Unless stated otherwise, methods will die when encountering an error.

# PKCS#11 MECHANISMS

The default mechanisms are:

# SEE ALSO

[PKCS#11 v2.40 Mechanisms](http://docs.oasis-open.org/pkcs11/pkcs11-curr/v2.40/os/pkcs11-curr-v2.40-os.html)
[Crypt::PKCS11](https://metacpan.org/pod/Crypt::PKCS11)
[SoftHSM2](https://www.opendnssec.org/softhsm/)

# AUTHOR

Ioan Rogers <ioan.rogers@sophos.com>

# COPYRIGHT AND LICENSE

This software is copyright (c) 2016 by Sophos Ltd.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
