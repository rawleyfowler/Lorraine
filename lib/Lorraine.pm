package Lorraine;

use strict;
use warnings;

use Carp ();
use Plack;
use Plack::HTTPParser qw( parse_http_request );
use IO::Socket::INET;
use IO::Tee;
use HTTP::Date;
use HTTP::Status;
use List::Util qw(max sum);
use Plack::Util;
use Stream::Buffered;
use Plack::Middleware::ContentLength;
use POSIX  qw(EINTR);
use Socket qw(:all);

require XSLoader;
XSLoader::load();

$HTTP::Server::PSGI::VERSION = '0.0.1';
use base qw(HTTP::Server::PSGI);

sub new {
    my ( $class, %args ) = @_;

    my $self = bless {
        (
            $args{listen_sock}
            ? (
                listen_sock => $args{listen_sock},
                host        => $args{listen_sock}->sockhost,
                port        => $args{listen_sock}->sockport,
              )
            : (
                host => $args{host}
                  || 0,
                port => $args{port}
                  || 8080,
            )
        ),
        timeout         => $args{timeout}         || 300,
        server_software => $args{server_software} || $class,
        server_ready    => $args{server_ready}    || sub { },
        ssl             => $args{ssl},
        ipv6            => $args{ipv6},
        ssl_key_file    => $args{ssl_key_file},
        ssl_cert_file   => $args{ssl_cert_file},
        refork_after    => $args{refork_after} || 5,
        num_workers     => $args{num_workers}  || 4
    }, $class;

    return $self;
}

sub accept_loop {
    my ( $self, $app ) = @_;

    # See
    if ( !Lorraine::set_child_subreaper() ) {
        Carp::croak(
'Got bad response from setting prctl SET_CHILD_SUBREAPER? Is your system POSIX??'
        );
    }

    my $pid = fork();

    pipe( my $mold_read, my $mold_write );
    if ( $pid != 0 ) {
        $self->{mold_pid} = $pid;

        my $mold_count = 0;

        while (1) {
            while (<$mold_read>) {
                chomp( my $new_mold = $_ );
                $self->{mold_pid} = $new_mold;
            }
        }
    }
    else {
      MOLD:
        my @children;
        my @children_handles;
        for ( 1 .. $self->{num_workers} ) {
            pipe( my $child_read, my $child_write );
            $self->{child_write} = $child_write;
            my $pid = fork();
            if ( $pid != 0 ) {
                push @children,         $pid;
                push @children_handles, $child_read;
            }
            else {
                $self->{refork_pid} = $pid;
                goto LOOP;
            }
        }

        my $cnt    = 0;
        my $handle = IO::Tee->new(@children_handles);
        while (1) {
            while ( chomp( my $child_pid = <$handle> ) ) {
                $cnt++;
                if ( $cnt >= $self->{refork_after} ) {
                    for (@children) {
                        kill $_ unless $_ eq $child_pid;
                    }
                    close($handle);

                    # Turns $child_pid process into the new mold,
                    # AKA: the most recently used child.
                    print $mold_write, "$child_pid\n";
                    kill 30, $child_pid;
                    exit 0;
                }
            }
        }
    }

  LOOP:
    my $writer       = $self->{child_write};
    my $pid_to_write = $self->{refork_pid} . "\n";
    $app = Plack::Middleware::ContentLength->wrap($app);
    while (1) {
        local $SIG{PIPE} = 'IGNORE';
        local $SIG{KILL} = sub {
            close( $self->{child_write} );
            exit 0;
        };

        # Mechanism for the MOLD to be reforked.
        local $SIG{USR1} = sub {
            close( $self->{child_write} );
            goto MOLD;
        };
        if ( my $conn = $self->{listen_sock}->accept ) {

            if ( defined TCP_NODELAY ) {
                $conn->setsockopt( IPPROTO_TCP, TCP_NODELAY, 1 )
                  or die "setsockopt(TCP_NODELAY) failed:$!";
            }

            my $env = {
                SERVER_PORT            => $self->{port},
                SERVER_NAME            => $self->{host},
                SCRIPT_NAME            => '',
                REMOTE_ADDR            => $conn->peerhost,
                REMOTE_PORT            => $conn->peerport || 0,
                'psgi.version'         => [ 1, 1 ],
                'psgi.errors'          => *STDERR,
                'psgi.url_scheme'      => $self->{ssl} ? 'https' : 'http',
                'psgi.run_once'        => Plack::Util::FALSE,
                'psgi.multithread'     => Plack::Util::FALSE,
                'psgi.multiprocess'    => Plack::Util::FALSE,
                'psgi.streaming'       => Plack::Util::TRUE,
                'psgi.nonblocking'     => Plack::Util::FALSE,
                'psgix.harakiri'       => Plack::Util::TRUE,
                'psgix.input.buffered' => Plack::Util::TRUE,
                'psgix.io'             => $conn,
            };

            $self->handle_connection( $env, $conn, $app );
            $conn->close;

            # Tell the mold we handled a request
            print $writer $pid_to_write;

            last if $env->{'psgix.harakiri.commit'};
        }
    }
}

1;
