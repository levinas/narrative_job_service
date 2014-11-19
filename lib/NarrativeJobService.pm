package NarrativeJobService;

use strict;
use warnings;

use JSON;
use Template;
use LWP::UserAgent;
use HTTP::Request::Common;
use Config::Simple;
use Data::Dumper;

1;

# set object variables from ENV
sub new {
	my ($class) = @_;

	my $agent = LWP::UserAgent->new;
	my $json  = JSON->new;
    $json = $json->utf8();
    $json->max_size(0);
    $json->allow_nonref;

	my $self = {
	    agent     => $agent,
	    json      => $json,
	    token	  => undef,
	    ws_url    => $ENV{'WS_SERVER_URL'},
		awe_url   => $ENV{'AWE_SERVER_URL'},
		shock_url => $ENV{'SHOCK_SERVER_URL'},
		client_group     => $ENV{'AWE_CLIENT_GROUP'},
		script_wrapper   => undef,
		service_wrappers => {},
	};

	bless $self, $class;
	$self->readConfig();
	return $self;
}

sub agent {
    my ($self) = @_;
    return $self->{'agent'};
}
sub json {
    my ($self) = @_;
    return $self->{'json'};
}
sub token {
    my ($self, $value) = @_;
    if (defined $value) {
        $self->{'token'} = $value;
    }
    return $self->{'token'};
}
sub ws_url {
    my ($self) = @_;
    return $self->{'ws_url'};
}
sub awe_url {
    my ($self) = @_;
    return $self->{'awe_url'};
}
sub shock_url {
    my ($self) = @_;
    return $self->{'shock_url'};
}
sub client_group {
    my ($self) = @_;
    return $self->{'client_group'};
}
sub script_wrapper {
    my ($self) = @_;
    return $self->{'script_wrapper'};
}
sub service_wrappers {
    my ($self) = @_;
    return $self->{'service_wrappers'};
}

# replace object variables from config if don't exit
sub readConfig {
    my ($self) = @_;
    # get config
    my $conf_file = $ENV{'KB_TOP'}.'/deployment.cfg';
    unless (-e $conf_file) {
        die "error: deployment.cfg not found ($conf_file)";
    }
    my $cfg_full = Config::Simple->new($conf_file);
    my $cfg = $cfg_full->param(-block=>'narrative_job_service');
    # get values
    foreach my $val (('ws_url', 'awe_url', 'shock_url', 'client_group', 'script_wrapper')) {
        unless (defined $self->{$val} && $self->{$val} ne '') {
            $self->{$val} = $cfg->{$val};
            unless (defined($self->{$val}) && $self->{$val} ne "") {
                die "$val not found in config";
            }
        }
    }
    # get service wrapper info
    my @services = @{$cfg->{'supported_services'}};
    my @wrappers = @{$cfg->{'service_wrappers'}};
    for (my $i=0; $i<@services; $i++) {
        $self->{'service_wrappers'}->{$services[$i]} = $wrappers[$i];
    }
}

### output of run_app, check_app_state:
#{
#    string job_id;
#    string job_state;
#    string running_step_id;
#    mapping<string, string> step_outputs;
#    mapping<string, string> step_errors;
#}

sub run_app {
    my ($self, $app, $user_name) = @_;

    my $tpage = Template->new(ABSOLUTE => 1);
    # build info
    my $info_vars = {
        app_name     => $app->{name},
        user_id      => $user_name,
        client_group => $self->client_group
    };
    
    my $info_temp = _info_template();
    my $info_str  = "";
    $tpage->process(\$info_temp, $info_vars, \$info_str) || return ({}, "[tpage error] ".$tpage->error());
    # start workflow
    my $workflow = {
        info => $self->json->decode($info_str),
        tasks => []
    };
    
    # build tasks
    my $tnum = 0;
    foreach my $step (@{$app->{steps}}) {
        # check type
        unless (($step->{type} eq 'script') || ($step->{type} eq 'service')) {
            return ({}, "[step error] invalid step type '".$step->{type}."' for ".$step->{step_id});
        }
        my $service = $step->{$step->{type}};
        
        # task templating
        my $task_vars = {
            cmd_name   => "",
            arg_list   => "",
            kb_service => $service->{service_name},
            kb_method  => $service->{method_name},
            kb_type    => $step->{type},
            user_token => $self->token,
            shock_url  => $self->shock_url,
            step_id    => $step->{step_id},
            # for now just the previous task
            depends_on => ($tnum > 0) ? '"'.($tnum-1).'"' : "",
            this_task  => $tnum,
            inputs     => ""
        };
        # shock input attr
        my $in_attr = {
            type        => "kbase_app",
            app         => $app->{name},
            user        => $user_name,
            step        => $step->{step_id},
            service     => $service->{service_name},
            method      => $service->{method_name},
            method_type => $step->{type},
            data_type   => "input",
            format      => "json"
        };
        
        # service step
        if ($step->{type} eq 'service') {
            # we have no wrapper
            unless (exists $self->service_wrappers->{$service->{service_name}}) {
                return ({}, "[service error] unsupported service '".$service->{service_name}."' for ".$step->{step_id});
            }
            my $fname = 'parameters.json';
            my ($arg_hash, $herr) = $self->_hashify_args($step->{parameters});
            if ($herr) {
                return ({}, $herr);
            }
            my ($input_hash, $perr) = $self->_post_shock_file($in_attr, $arg_hash, $fname);
            if ($perr) {
                return ({}, $perr);
            }
            $task_vars->{inputs}   = '"inputs": '.$self->json->encode($input_hash).",\n";
            $task_vars->{cmd_name} = $self->service_wrappers->{$service->{service_name}};
            $task_vars->{arg_list} = $service->{method_name}." @".$fname." ".$service->{service_url};
        }
        # script step
        elsif ($step->{type} eq 'script') {
            # use wrapper
            if ($service->{has_files}) {
                my $fname = 'parameters.json';
                my $arg_hash = {};
                my ($input_hash, $perr) = $self->_post_shock_file($in_attr, $arg_hash, $fname);
                if ($perr) {
                    return ({}, $perr);
                }
                $task_vars->{inputs}   = '"inputs": '.$self->json->encode($input_hash).",\n";
                $task_vars->{cmd_name} = $self->script_wrapper;
                $task_vars->{arg_list} = "--params @".$fname." ".$service->{method_name};
            }
            # run given cmd
            else {
                my ($arg_str, $serr) = $self->_stringify_args($step->{parameters});
                if ($serr) {
                    return ({}, $serr);
                }
                $task_vars->{cmd_name} = $service->{method_name};
                $task_vars->{arg_list} = $arg_str;
            }
        }
        # process template / add to workflow
        my $task_temp = _task_template();
        my $task_str  = "";
        $tpage->process(\$task_temp, $task_vars, \$task_str) || return ({}, "[tpage error] ".$tpage->error());
        $workflow->{tasks}->[$tnum] = $self->json->decode($task_str);
        $tnum += 1;
    }

    # submit workflow
    my ($job, $jerr) = $self->_post_awe_workflow($workflow);
    if ($jerr) {
        return ({}, $jerr);
    }
    # return app info
    my ($output, $oerr) = $self->check_app_state(undef, $job);
    return ($output, $oerr);
}

sub check_app_state {
    my ($self, $job_id, $job) = @_;
    
    # get job doc
    unless ($job && ref($job)) {
        my ($job_doc, $err) = $self->_awe_job_action($job_id, 'get');
        if ($err) {
            return ({}, $err);
        }
        $job = $job_doc;
    }
    # set output
    my $output = {
        job_id          => $job->{id},
        job_state       => $job->{state},
        running_step_id => "",
        step_outputs    => {},
        step_errors     => {}
    };
    # parse each task
    foreach my $task (@{$job->{tasks}}) {
        my $step_id = $task->{userattr}->{step};
        # get running
        if (($task->{state} eq 'queued') || ($task->{state} eq 'in-progress')) {
            $output->{running_step_id} = $step_id;
        }
        # get stdout text
        if (exists($task->{outputs}{'awe_stdout.txt'}) && $task->{outputs}{'awe_stdout.txt'}{url}) {
            my ($content, $err) = $self->_shock_node_file($task->{outputs}{'awe_stdout.txt'}{url});
            if ($err) {
                return ({}, $err);
            }
            $output->{step_outputs}{$step_id} = $content;
        }
        # get stderr text
        if (exists($task->{outputs}{'awe_stderr.txt'}) && $task->{outputs}{'awe_stderr.txt'}{url}) {
            my ($content, $err) = $self->_shock_node_file($task->{outputs}{'awe_stderr.txt'}{url});
            if ($err) {
                return ({}, $err);
            }
            $output->{step_errors}{$step_id} = $content;
        }
    }
    return ($output, undef);
}

sub suspend_app {
    my ($self, $job_id) = @_;
    my ($result, $err) = $self->_awe_job_action($job_id, 'put', 'suspend');
    if ($err) {
        return ("", $err);
    } elsif ($result =~ /^job suspended/) {
        return ("success", undef);
    } else {
        return ("failure", undef);
    }
}

sub resume_app {
    my ($self, $job_id) = @_;
    my ($result, $err) = $self->_awe_job_action($job_id, 'put', 'resume');
    if ($err) {
        return ("", $err);
    } elsif ($result =~ /^job resumed/) {
        return ("success", undef);
    } else {
        return ("failure", undef);
    }
}

sub delete_app {
    my ($self, $job_id) = @_;
    my ($result, $err) = $self->_awe_job_action($job_id, 'delete');
    if ($err) {
        return ("", $err);
    } elsif ($result =~ /^job deleted/) {
        return ("success", undef);
    } else {
        return ("failure", undef);
    }
}

sub list_config {
    my ($self) = @_;
    my $cfg = {
        ws_url    => $self->ws_url,
		awe_url   => $self->awe_url,
		shock_url => $self->shock_url,
		client_group   => $self->client_group,
		script_wrapper => $self->script_wrapper
    };
    foreach my $s (keys %{$self->service_wrappers}) {
        $cfg->{$s} = $self->service_wrappers->{$s};
    }
    return $cfg;
}

# returns: (data, err_msg)
sub _awe_job_action {
    my ($self, $job_id, $action, $options) = @_;

    my $response = undef;
    my $url = $self->awe_url.'/job/'.$job_id;
    if ($options) {
        $url .= "?".$options;
    }
    my @args = ('Authorization', 'OAuth '.$self->token);

    eval {
        my $tmp = undef;
        if ($action eq 'delete') {
            $tmp = $self->agent->delete($url, @args);
        } elsif ($action eq 'put') {
            my $req = POST($url, @args);
            $req->method('PUT');
            $tmp = $self->agent->request($req);
        } elsif ($action eq 'get') {
            $tmp = $self->agent->get($url, @args);
        }
        $response = $self->json->decode( $tmp->content );
    };

    if ($@ || (! ref($response))) {
        return (undef, $@ || "[awe error] unable to connect to AWE server");
    } elsif (exists($response->{error}) && $response->{error}) {
        my $err = $response->{error}[0];
        if ($err eq "Not Found") {
            $err = "job $job_id does not exist";
        }
        return (undef, "[awe error] ".$err);
    } else {
        return ($response->{data}, undef);
    }
}

# return: (job_doc, err_msg)
sub _post_awe_workflow {
    my ($self, $workflow) = @_;

    my $response = undef;
    my $content  = { upload => [undef, "kbase_app.awf", Content => $self->json->encode($workflow)] };
    my @args = (
        'Authorization', 'OAuth '.$self->token,
        'Datatoken', $self->token,
        'Content_Type', 'multipart/form-data',
        'Content', $content
    );
    
    eval {
        my $post = $self->agent->post($self->awe_url.'/job', @args);
        $response = $self->json->decode( $post->content );
    };
    
    if ($@ || (! $response)) {
        return (undef, $@ || "[awe error] unable to connect to AWE server");
    } elsif (exists($response->{error}) && $response->{error}) {
        return (undef, "[awe error] ".$response->{error}[0]);
    } else {
        return ($response->{data}, undef);
    }
}

# returns: (node_file_str, err_msg)
sub _get_shock_file {
    my ($self, $url) = @_;
    
    my $response = undef;
    eval {
        $response = $self->agent->get($url, 'Authorization', 'OAuth '.$self->token);
    };
    if ($@ || (! $response)) {
        return (undef, $@ || "[shock error] unable to connect to Shock server");
    }
    
    # if return is json encoded get error
    eval {
        my $json = $self->json->decode( $response->content );
        if (exists($json->{error}) && $json->{error}) {
            return (undef, "[shock error] ".$json->{error}[0]);
        }
    };
    # get content
    return ($response->content, undef);
}

# returns: (awe_input_struct, err_msg)
sub _post_shock_file {
    my ($self, $attr, $data, $fname) = @_;
    
    my $response = undef;
    my $content  = {
        upload => [undef, $fname, Content => $self->json->encode($data)],
        attributes => [undef, "$fname.json", Content => $self->json->encode($attr)]
    };
    my @args = (
        'Authorization', 'OAuth '.$self->token,
        'Content_Type', 'multipart/form-data',
        'Content', $content
    );
    
    eval {
        my $post = $self->agent->post($self->shock_url.'/node', @args);
        $response = $self->json->decode( $post->content );
    };
    
    if ($@ || (! $response)) {
        return (undef, $@ || "[shock error] unable to connect to Shock server");
    } elsif (exists($response->{error}) && $response->{error}) {
        return (undef, "[shock error] ".$response->{error}[0]);
    } else {
        my $input = {
            $fname => {
                host => $self->shock_url,
                node => $response->{data}{id}
            }
        };
        return ($input, undef);
    }
}

sub _hashify_args {
    my ($self, $params) = @_;
    my $arg_hash = {};
    for (my $i=0; $i<@$params; $i++) {
        my $p = $params->[$i];
        unless ($p->{label}) {
            return (undef, "[step error] parameter number ".$i." is not valid, label is missing");
        }
        $arg_hash->{$p->{label}} = $p->{value};
    }
    return ($arg_hash, undef);
}

sub _stringify_args {
    my ($self, $params) = @_;
    my @arg_list = ();
    for (my $i=0; $i<@$params; $i++) {
        my $p = $params->[$i];
        if ($p->{label} =~ /\s/) {
            return (undef, "[step error] parameter number ".$i." is not valid, label '".$p->{label}."' may not contain whitspace");
        }
        # short option
        elsif (length($p->{label}) == 1) {
            push @arg_list, "-".$p->{label};
        }
        # long option
        elsif (length($p->{label}) > 1) {
            push @arg_list, "--".$p->{label};
        }
        # has value
        if ($p->{value}) {
            push @arg_list, $p->{value};
        }
    }
    return (join(" ", @arg_list), undef);
}

sub _info_template {
    return qq(
    {
        "pipeline": "narrative_job_service",
        "name": "[% app_name %]",
        "user": "[% user_id %]",
        "clientgroups": "[% client_group %]",
        "userattr": {
            "type": "kbase_app",
            "app": "[% app_name %]",
            "user": "[% user_id %]"
        }
    });
}

sub _task_template {
    return qq(
    {
        "cmd": {
            "name": "[% cmd_name %]",
            "args": "[% arg_list %]",
            "description": "[% kb_service %].[% kb_method %]",
            "environ": {
                "private": {
                    "KB_AUTH_TOKEN": "[% user_token %]"
                }
            }
        },
        "dependsOn": [[% dependent_tasks %]],
        [% inputs %]
        "outputs": {
            "awe_stdout.txt": {
                "host": "[% shock_url %]",
                "node": "-",
                "attrfile": "userattr.json"
            },
            "awe_stderr.txt": {
                "host": "[% shock_url %]",
                "node": "-",
                "attrfile": "userattr.json"
            }
        },
        "userattr": {
            "step": "[% step_id %]",
            "service": "[% kb_service %]",
            "method": "[% kb_method %]",
            "method_type": "[% kb_type %]",
            "data_type": "output",
            "format": "text"
        },
        "taskid": "[% this_task %]",
        "totalwork": 1
    });
}

