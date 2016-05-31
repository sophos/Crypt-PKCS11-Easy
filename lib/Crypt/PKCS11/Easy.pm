package Crypt::PKCS11::Easy;

# ABSTRACT: Wrapper around Crypt::PKCS11 to make using a HSM not suck

use v5.16.3;    # CentOS7
use Crypt::PKCS11 qw/:constant_names :constant/;
use Crypt::PKCS11::Attributes;
use Log::Any '$log';
use Path::Tiny;
use Safe::Isa;
use Try::Tiny;
use Types::Standard qw/ArrayRef Str/;
use Types::Path::Tiny 'AbsFile';
use version;
use Moo;
use namespace::clean;

use experimental 'smartmatch';

=attr C<module>

String. Required.

The name of the PKCS#11 module to use. Either pass the full path to the module,
or just pass the base name of the library and the rest will be handled
automagically. e.g.

  libsofthsm2          => /usr/lib64/pkcs11/libsofthsm2.so
  libCryptoki2_64      => /usr/lib64/pkcs11/libCryptoki2_64.so
  gnome-keyring-pkcs11 => /usr/lib64/pkcs11/gnome-keyring-pkcs11.so

=cut

has module => (
    is       => 'ro',
    required => 1,
    isa      => Str,
);

has _module => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $self = shift;

        # is module already a Path::Tiny object?
        return $self->module if $self->module->$_isa('Path::Tiny');

        # does module look like a path?
        return path($self->module)->absolute if $self->module =~ m|/|;

        # TODO care about non-linux?
        # just a string, lets try to find a module
        my $module_name = sprintf '%s.so', $self->module;
        my $full_module_path;
        for (@{$self->_module_dirs}) {
            next unless $_->child($module_name)->is_file;
            $full_module_path = $_->child($module_name);
        }
        if (!$full_module_path) {
            die 'Unable to find a module for ' . $self->module;
        }
        return $full_module_path;
    },

    isa => AbsFile,
);

=attr C<rw>

Boolean. Controls whether a session will be opened in Read/Write mode or not.
Defaults to off. Writing is only needed to make modifications to a token or the
objects on it.

=cut

has rw => (is => 'ro', default => 0);

=attr C<key>

String. The label of the you want to use.

=cut

has key => (is => 'ro', predicate => 1);

=attr C<function>

String. The function that will be performed with this object. Can be 'sign' or
'verify'. Defaults to 'sign'. It affects how the key can be used. If function is
sign and you try to verify a signature, the underlying library will return an
error.

=cut

has function => (is => 'ro', default => 'sign');

=attr C<slot>

Integer. The id number of the slot to use.

=cut

has slot => (is => 'lazy');

=attr C<token>

String. Instead of specifying the L</slot>, find and use the slot that contains
a token with this label.

=cut

has token => (is => 'ro', predicate => 1);

=attr C<pin>

String, Coderef or L<Path::Tiny> object. This is either the PIN/password required
to access a token, a coderef that returns it, or a file that contains it.

 use IO::Prompter;
 $pin = sub { prompt 'Enter PIN: ', -echo=>'*' };

 use Path::Tiny;
 $pin = path '/secure/file/with/password'

 $pin = '1234';

=cut

has pin => (is => 'ro', required => 0);

=attr C<module_dirs>

Array of paths to check for PKCS#11 modules.

=cut

has module_dirs => (
    is      => 'ro',
    lazy    => 1,
    isa     => ArrayRef,
    default => sub {
        [
            '/usr/lib64/pkcs11/', '/usr/lib/pkcs11',
            '/usr/lib/x86_64-linux-gnu/pkcs11/'
        ];
    },
);

has _pkcs11 => (is => 'rwp');

has _key => (is => 'lazy');

# to keep usage simple, only allowed one session per object
has _session => (is => 'lazy', predicate => 1);

# TODO allow overriding defaults, possibly using predefined groups of related mechs
has _default_mech => (
    is      => 'ro',
    default => sub {
        {
            sign   => CKM_SHA1_RSA_PKCS,
            verify => CKM_SHA1_RSA_PKCS,
            digest => CKM_SHA_1,
        };
    },
);

has _module_dirs => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $self = shift;
        my @paths;
        for (@{$self->module_dirs}) {
            my $path = path($_)->absolute;
            push @paths, $path if $path->is_dir;
        }
        die "No valid module paths found\n" if scalar @paths == 0;
        return \@paths;
    },
);

has _flags => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        {
            token => [
                qw/rng write_protected login_required user_pin_initialized
                  restore_key_not_needed clock_on_token protected_authentication_path
                  dual_crypto_operations token_initialized secondary_authentication
                  user_pin_count_low user_pin_final_try user_pin_locked so_pin_count_low
                  user_pin_to_be_changed so_pin_final_try so_pin_locked so_pin_to_be_changed
                  error_state
                  /
            ],
            mechanism => [
                qw/hw encrypt decrypt digest sign sign_recover verify verify_recover generate generate_key_pair wrap unwrap derive extension/
            ],
            slot => [qw/token_present removable_device hw_slot/],
        };
    },
);

has [qw/_token_flags _mechanism_flags _slot_flags/] => (is => 'lazy');

sub _build__mechanism_flags {
    _flags_to_hash($_[0]->_flags->{mechanism});
}

sub _build__token_flags {
    _flags_to_hash($_[0]->_flags->{token});
}

sub _build__slot_flags {
    _flags_to_hash($_[0]->_flags->{slot});
}

sub BUILD {
    my $self = shift;
    return $self->_set__pkcs11($self->_build__pkcs11);
}

sub _flags_to_hash {
    my $flags = shift;
    no strict 'refs';    ## no critic
    my %flag = map {
        my $f = 'Crypt::PKCS11::CKF_' . uc($_);
        $f->() => $_;
    } @$flags;

    return \%flag;
}

sub _build__pkcs11 {
    my $self = shift;

    $log->debug('Initialising PKCS#11...');

    # Create the main PKCS #11 object, load a PKCS #11 provider .so library and initialize the module
    my $pkcs11 = Crypt::PKCS11->new;

    $pkcs11->load($self->_module)
      or die sprintf "Failed to load PKCS11 module [%s]: %s\n",
      $self->_module, $pkcs11->errstr;

    $pkcs11->Initialize
      or die sprintf "Failed to initialize PKCS11 module [%s]: %s\n",
      $self->_module, $pkcs11->errstr;

    $log->debug("Loaded PKCS#11 module: " . $self->_module);

    return $pkcs11;
}

sub _build__key {
    my $self = shift;
    if (!$self->has_key) {
        die 'Tried to automagically find a key without a label';
    }

    $self->login;

    my $tmpl = Crypt::PKCS11::Attributes->new;

    given ($self->function) {
        return $self->get_signing_key($self->key) when 'sign';
        return $self->get_verification_key($self->key) when 'verify';
        default {
            die "Unknown key type: " . $self->function;
        }
    }

}

sub _build_slot {
    my $self = shift;

    # if token is set we can try to find a slot that contains that token
    if ($self->has_token) {
        my $slot = $self->get_slot(token => $self->token);
        return $slot->{id};
    }

    my $slot_ids = $self->_pkcs11->GetSlotList(1)
      or die 'Unable to find any available slots: ' . $self->_pkcs11->errstr;

    if (scalar @$slot_ids > 1) {
        die 'There is more than one slot available, specify the one to use';
    }

    return shift @$slot_ids;
}

sub _build__session {
    my $self = shift;

    # if this isn't called the Luna always gives UNKNOWN_ERROR when trying
    # to open a session
    $self->_pkcs11->CloseAllSessions($self->slot);

    # default to a ro session
    my $flags;
    if ($self->rw) {
        $log->debug('Opening a RW session');
        $flags = CKF_RW_SESSION | CKF_SERIAL_SESSION;
    } else {
        $log->debug('Opening a RO session');
        $flags = CKF_SERIAL_SESSION;
    }

    my $session = $self->_pkcs11->OpenSession($self->slot, $flags)
      or die sprintf 'Error opening session on slot %s: %s', $self->slot,
      $self->_pkcs11->errstr;

    $log->debug('Session opened on slot ' . $self->slot);
    return $session;
}

sub _clean_hash_values {
    my $h = shift;

    for (keys %$h) {

        if ($_ =~ /^(firmware|hardware|library|cryptoki)Version$/) {
            my $v = sprintf '%i.%i', $h->{$_}->{major}, $h->{$_}->{minor};
            $h->{$_} = version->parse($v);
            next;
        }

        next if ref $h->{$_};

        $h->{$_} =~
          s/\0$//;    # safenet cryptoki 2.2 has some null terminated strings
        $h->{$_} =~ s/\s*$//;
        delete $h->{$_} if length $h->{$_} == 0;
    }

    return;
}

=method C<get_info>

Returns a hashref containing basic info about the PKCS#11 implementation,
currently the manufacturer, library description and Cryptoki version that is
implemented.

=cut

sub get_info {
    my $self = shift;

    my $info = $self->_pkcs11->GetInfo
      or die 'Could not retrieve HSM info: ' . $self->_pkcs11->errstr;

    # according to v2.30 there are no flags and this is always 0
    delete $info->{flags};
    _clean_hash_values($info);
    return $info;
}

=method C<get_token_info(Int $slot_id)>

Returns a hashref containing details on the token in slot identified by
C<$slot_id>.

=cut

sub get_token_info {
    my ($self, $slot_id) = @_;

    my $token = $self->_pkcs11->GetTokenInfo($slot_id)
      or die "Unable to retrive token info for slot $slot_id: "
      . $self->_pkcs11->errstr;

    _clean_hash_values($token);

    for my $f (keys %{$self->_token_flags}) {
        $token->{flag}->{$self->_token_flags->{$f}} =
          ($token->{flags} & $f) ? 1 : 0;
    }

    delete $token->{flags};

    return $token;
}

=method C<get_slot(id => $int | token => $string)>

Returns a hashref containing details on the slot identified by C<$id> B<OR> the
slot which contains a C<token> with the label C<$string>. If a token is present
in the slot, its details will also be retrieved.

  my $slot = $pkcs11->get_slot(id => 1);

  my $slot = $pkcs11->get_slot(token => 'Build Signer');
  say $slot->{token}->{serialNumber};

=cut

sub get_slot {
    my ($self, %arg) = @_;

    unless (defined $arg{id} || defined $arg{token}) {
        die 'Missing id or token';
    }

    my ($slot, $slot_id);

    if (defined $arg{id}) {

        $log->debug("Retrieving info for slot $arg{id}");
        $slot = $self->_pkcs11->GetSlotInfo($arg{id})
          or die "Unable to retrieve info for slot $arg{id}: "
          . $self->_pkcs11->errstr;
        $slot_id = $arg{id};

    } elsif ($arg{token}) {

        $log->debug(
            "Searching for slot containing token labelled '$arg{token}'");
        my $slots = $self->get_slots(1);
        for (@$slots) {
            if ($_->{token}->{label} && $arg{token} eq $_->{token}->{label}) {
                return $_;

                # last;
            }
        }
        die "Unable to find slot containing token labelled '$arg{token}'"
          unless $slot;
    }

    # strip whitespace padding
    _clean_hash_values($slot);

    $slot->{id} = $slot_id;
    for my $f (keys %{$self->_slot_flags}) {
        $slot->{flag}->{$self->_slot_flags->{$f}} =
          ($slot->{flags} & $f) ? 1 : 0;
    }

    delete $slot->{flags};

    if ($slot->{flag}->{token_present}) {
        try {
            $slot->{token} = $self->get_token_info($slot_id);
        }
        catch {
            # there is a token present in this slot but details could not be retrieved.
            # SoftHSM doesn't require an open session to work, but the Safenet Luna does
            # the 2.20 docs don't show that a session is required...
            $log->debug("Failed to access slot, trying to open a session");
            my $session;
            if ($self->_has_session) {
                $session = $self->session;
            } else {
                $session =
                  $self->_pkcs11->OpenSession($slot_id, CKF_SERIAL_SESSION)
                  or die "Error opening session on slot $slot_id: "
                  . $self->_pkcs11->errstr;
            }
            $slot->{token} = $self->get_token_info($slot_id);

            $session->CloseSession;
        };
    }

    return $slot;
}

=method C<get_slots(Bool $with_token?)>

Returns an arrayref of all visible slots. Each element in the array will
be a hashref returned by L</get_slot>.

If C<$with_token> is true then only slots that contain a token will be returned.

=cut

sub get_slots {
    my ($self, $with_token) = @_;

    my $slot_ids = $self->_pkcs11->GetSlotList($with_token)
      or die 'Unable to find any available slots: ' . $self->_pkcs11->errstr;

    my @slots;
    for my $slot_id (sort @$slot_ids) {
        my $slot = $self->get_slot(id => $slot_id);
        push @slots, $slot;
    }

    return \@slots;
}

=method C<login>

Attempts to login to the HSM. In most use cases, this will be handled
automatically when needed.

=cut

sub login {
    my $self = shift;

    my $pin;

    given (ref $self->pin) {
        when ('CODE') {
            $log->debug('Getting PIN from coderef');
            $pin = $self->pin->();
        }
        when ('Path::Tiny') {
            $log->debug("Reading PIN from file: " . $self->pin);
            $pin = $self->pin->slurp;
        }
        default { $pin = $self->pin }
    }

    die 'No PIN/password specified and no way to get one is set' unless $pin;

    chomp $pin;

    $log->debug('Logging in to session');
    $self->_session->Login(CKU_USER, $pin)
      or die "Failed to login: " . $self->_session->errstr;

    return;
}

sub _get_key {
    my ($self, $label, $tmpl) = @_;

    $log->debug("Searching for key with label: $label");
    $tmpl->push(Crypt::PKCS11::Attribute::Label->new->set($label));
    $self->_session->FindObjectsInit($tmpl);

    # labels are supposed to be unique
    my $objects = $self->_session->FindObjects(1)
      or die "Couldn't find any key matching label $label: "
      . $self->_session->errstr;

    $self->_session->FindObjectsFinal;

    # pulObjectCount down in the XS would tell us how many results were returned
    if (scalar @$objects == 0) {
        die "Failed to find a key matching label $label";
    }

    $log->debug("Found key $label");
    return shift @$objects;
}

=method C<get_signing_key(Str $label)>

Will look for a key matching with a label matching C<$label> which can be used
for signing.

The returned key is a L<Crypt::PKCS11::Object>.

=cut

sub get_signing_key {
    my ($self, $label) = @_;

    my $tmpl =
      Crypt::PKCS11::Attributes->new->push(
        Crypt::PKCS11::Attribute::Sign->new->set(1),
      );

    return $self->_get_key($label, $tmpl);
}

=method C<get_verification_key(Str $label)>

Will look for a key matching with a label matching C<$label> which can be used
for signature verification.

The returned key is a L<Crypt::PKCS11::Object>.
=cut

sub get_verification_key {
    my ($self, $label) = @_;

    my $tmpl =
      Crypt::PKCS11::Attributes->new->push(
        Crypt::PKCS11::Attribute::Verify->new->set(1),
      );

    return $self->_get_key($label, $tmpl);
}

sub _handle_common_args {
    my $args = shift;

    return if $args->{data};
    die 'Missing filename or data' unless $args->{file};

    my $file = delete $args->{file};

    # a filename or a Path::Tiny object
    if (!ref $file) {
        $file = path $file;
    } elsif (ref $file ne 'Path::Tiny') {
        die "Don't know how to handle a " . ref $file;
    }
    $args->{data} = $file->slurp_raw;

    if ($args->{mech}) {
        $args->{mech} =~ s/-/_/g;
        my $const = 'Crypt::PKCS11::CKM_' . $args->{mech};
        $log->debug("Attempting to use mechanism: $const");
        no strict 'refs';    ## no critic
        my $mech = Crypt::PKCS11::CK_MECHANISM->new;
        $mech->set_mechanism($const->());
        $args->{mech} = $mech;
    }

    return;
}

=method C<sign((data => 'some data' | file => '/path'), mech => 'RSA_PKCS'?)>

Returns a binary signature. The data to be signed is either passed as a scalar
in C<data>, or in C<file> which can be a string path or a L<Path::Tiny> object.

A PKCS#11 mechanism can optionally be specified as a string and without the
leading 'CKM_'.

  my $sig = $hsm->sign(file => $file, mech => 'RSA_PKCS');
  my $sig = $hsm->sign(data => 'SIGN ME');

=cut

sub sign {
    my ($self, %args) = @_;

    _handle_common_args(\%args);

    if (!$args{mech}) {
        $args{mech} = Crypt::PKCS11::CK_MECHANISM->new;
        $args{mech}->set_mechanism($self->_default_mech->{sign});
    }

    $self->_session->SignInit($args{mech}, $self->_key)
      or die "Failed to init signing: " . $self->_session->errstr;

    my $sig = $self->_session->Sign($args{data})
      or die "Failed to sign: " . $self->_session->errstr;

    return $sig;
}

=method C<sign_and_encode(...)>

Wrapper around L</sign> which will return the signature data as base64 PEM, e.g.

  -----BEGIN SIGNATURE-----
  YHXMbvdWyUXeNvgfMzQA+9FjytOWPZCik/H3GS6t72xtk1gvHNfQpKdURKvgBeJM
  QdUJ7ceujzGX5v/UJRJ4oSpLLiptn2BYaeAn/gUg7yKDFg4YuVN7RU7MbrN2jjlw
  RfKHq6h6G4FP8LJz5jQWlKKIPoiJ2g3a9M7dq0+hG/kPOv4pBLm7G30uaiSpi/3O
  hhV+aw87HB7H7i09NSIHoWRxXqw8BeFse7jWTjbj5X1j9uNxD+W6+sxyERawfqFP
  3WuzDIcD8kgMA7cM7a6z+h1bEgUt2FUKGytcTX4ymAz9+aS+u24V81mg0Ia3pZQd
  Pth2532FY0z+Ajn3GojNVw==
  -----END SIGNATURE-----

=cut

sub sign_and_encode {
    my $self = shift;

    require MIME::Base64;
    my $sig_encoded = MIME::Base64::encode_base64($self->sign(@_), '');

    my @lines = unpack '(a64)*', $sig_encoded;

    return sprintf "-----BEGIN SIGNATURE-----\n%s\n-----END SIGNATURE-----\n",
      (join "\n", @lines);

}

=method C<verify((data => 'some data' | file => '/path'), sig => $sig, mech => 'RSA_PKCS'?)>

Verifies a signature. Parameters are the same as L</sign>, and also requires
a binary signature. Returns true or false.

  $hsm->verify(file => $file_to_check, sig => $binary_sig, mech => 'RSA_PKCS')
      or die "Signature verification failed!\n";

=cut

sub verify {
    my ($self, %args) = @_;

    die 'Missing signature' unless $args{sig};
    _handle_common_args(\%args);

    if (!$args{mech}) {
        $args{mech} = Crypt::PKCS11::CK_MECHANISM->new;
        $args{mech}->set_mechanism($self->_default_mech->{verify});
    }

    $self->_session->VerifyInit($args{mech}, $self->_key)
      or die 'Failed to init verify ' . $self->_session->errstr;

    my $v = $self->_session->Verify($args{data}, $args{sig});

    $log->info($self->_session->errstr) unless $v;

    return $v;
}

=method C<digest((data => 'some data' | file => '/path'), mech => 'SHA_1'?)>

Returns a binary digest. Parameters are the same as L</sign>.

  $hsm->digest(file => $file_to_check, mech => 'RSA_PKCS')

=cut

sub digest {
    my ($self, %args) = @_;

    _handle_common_args(\%args);

    if (!$args{mech}) {
        $args{mech} = Crypt::PKCS11::CK_MECHANISM->new;
        $args{mech}->set_mechanism($self->_default_mech->{digest});
    }

    $self->_session->DigestInit($args{mech})
      or die 'Failed to init digest ' . $self->_session->errstr;

    my $d = $self->_session->Digest($args{data});
    $log->info($self->_session->errstr) unless $d;
    return $d;
}

# This shouldn't be here, it's not HSM specific.
# Also, CPAN must surely have a cert/key loading module

=method C<decode_signature((data => 'some data' | file => '/path'))>

Verifies a signature. Parameters are the same as L</sign>, and also requires
a binary signature. Returns true or false.

  $hsm->verify(file => $file_to_check, sig => $binary_sig, mech => 'RSA_PKCS')
      or die "Signature verification failed!\n";

=cut

sub decode_signature {
    my ($self, %args) = @_;

    _handle_common_args(\%args);

    require MIME::Base64;

    say $args{data};

    $args{data} =~ /^-----BEGIN SIGNATURE-----(.+)-----END SIGNATURE-----/s;
    die 'Unable to find signature in data' unless $1;

    return MIME::Base64::decode_base64($1);
}

=method C<get_mechanism_info($mech, $slot_id?)>

Will return a details of a mechanism as a hashref. If a slot id is specifed, the
mechanisms for that slot will be retrieved. Otherwise, the slot id in L</slot>
 will be used if there is one.

=cut

sub get_mechanism_info {
    my ($self, $mech, $slot_id) = @_;

    $slot_id //= $self->slot;

    my $mech_info = $self->_pkcs11->GetMechanismInfo($slot_id, $_)
      or die 'Failed to get mechanism info ' . $self->_pkcs11->errstr;

    for my $f (keys %{$self->_mechanism_flags}) {
        $mech_info->{flag}->{$self->_mechanism_flags->{$f}} =
          ($mech_info->{flags} & $f) ? 1 : 0;
    }

    delete $mech_info->{flags};

    return $mech_info;
}

=method C<get_mechanisms($slot_id?)>

Will return a hashref of available mechanisms. If a slot id is specifed, the
mechanisms for that slot will be retrieved. Otherwise, the slot id in L</slot>
 will be used if there is one.

=cut

# TODO might be nice to filter mechanisms by flags, e.g. give me all the mechs
# that can be used for singing
sub get_mechanisms {
    my $self    = shift;
    my $slot_id = shift;

    $slot_id //= $self->slot;

    $log->debug("Fetching mechanisms for slot $slot_id");
    my $mech_list = $self->_pkcs11->GetMechanismList($slot_id)
      or die 'Failed to get mechanisms ' . $self->_pkcs11->errstr;

    my %mech = map {
        my $name = $CKM_NAME{$_} ? $CKM_NAME{$_} : $_;
        $name => $self->get_mechanism_info($_, $slot_id);
    } @$mech_list;
    return \%mech;
}

1;

__END__

=head1 STATUS

=begin HTML

<div>
    <a href="https://travis-ci.org/sophos/Crypt-PKCS11-Easy"><img src="https://travis-ci.org/sophos/Crypt-PKCS11-Easy.svg?branch=master"></a>
</div>

=end HTML

=head1 SYNOPSIS

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

=head1 DIAGNOSTICS

C<Crypt::PKCS11::Easy> uses L<Log::Any> for logging. To see debug output on
C<STDOUT>, for example, in your application use:

    use Log::Any::Adapter 'Stdout', log_level => 'debug';

=head1 ERRORS

Unless stated otherwise, methods will die when encountering an error.

=head1 DESCRIPTION

This module is an OO wrapper around L<Crypt::PKCS11>, designed primarily to make
using a HSM as simple as possible.

=head2 Signing a file with C<Crypt::PKCS11>

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

=head2 Signing a file with C<Crypt::PKCS11::Easy>

    use Crypt::PKCS11::Easy;
    use IO::Prompter;

    my $hsm = Crypt::PKCS11::Easy->new(
        module => 'libCryptoki2_64',
        key    => 'MySigningKey',
        slot   => '0',
        pin    => sub { prompt 'Enter PIN: ', -echo=>'*' },
    );

    my $sig = $hsm->sign(data => 'SIGN ME');

To make that conciseness possible a C<Crypt::PKCS11::Object> can only be used
for one function, e.g. signing OR verifying, and cannot be set to use a
different key or a different token after instantiation. A new object should be
created for each function.

=head1 PKCS#11 MECHANISMS

The default mechanisms are:

=for :list
* Signing
C<CKM_SHA1_RSA_PKCS>
* Digesting
C<CKM_SHA1>

=head1 SEE ALSO

L<PKCS#11 v2.40 Mechanisms|http://docs.oasis-open.org/pkcs11/pkcs11-curr/v2.40/os/pkcs11-curr-v2.40-os.html>
L<Crypt::PKCS11>
L<SoftHSM2|https://www.opendnssec.org/softhsm/>
