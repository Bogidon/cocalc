###
Jupyter Backend
###

{EventEmitter} = require('events')

fs = require('fs')

misc = require('smc-util/misc')
{defaults, required} = misc

exports.jupyter_backend = (syncdb, client) ->
    dbg = client.dbg("jupyter_backend")
    dbg()
    {JupyterActions} = require('smc-webapp/jupyter/actions')
    {JupyterStore}   = require('smc-webapp/jupyter/store')
    smc_react        = require('smc-webapp/smc-react')

    project_id = client.client_id()
    path       = syncdb._path
    redux_name = smc_react.redux_name(project_id, path)
    actions    = new JupyterActions(redux_name, smc_react.redux)
    store      = new JupyterStore(redux_name, smc_react.redux)

    actions._init(project_id, path, syncdb, store, client)

    syncdb.once 'init', (err) ->
        dbg('syncdb init complete #{err}')

exports.kernel = (opts) ->
    opts = defaults opts,
        name : required   # name of the kernel as a string
    return new Kernel(opts.name)

class Kernel extends EventEmitter
    constructor : (@name) ->
        @_state = 'init'
        @_identity = misc.uuid()
        require('spawnteract').launch(@name).then (kernel) =>
            @_kernel = kernel
            @_channels = require('enchannel-zmq-backend').createChannels(@_identity, @_kernel.config)
            @_channels.shell.subscribe((mesg) => @emit('shell', mesg))
            @_channels.iopub.subscribe((mesg) => @emit('iopub', mesg))
            @_state = 'running'
            @emit('init')

    execute_code: (opts) =>
        opts = defaults opts,
            code : required
            cb   : required    # this happens **repeatedly**:  cb(undefined, output message)
        if not @_channels?
            if @_state == 'closed'
                opts.cb("closed")
            else
                # wait until kernel/channels are setup, then try again.
                @once('init', => @execute_code(opts))
            return
        message =
            header:
                msg_id   : "execute_#{misc.uuid()}"
                username : 'cocalc'
                session  : '00000000-0000-0000-0000-000000000000'
                msg_type : 'execute_request'
                version  : '5.0'
            content:
                code             : opts.code
                silent           : false
                store_history    : true
                user_expressions : {}
                allow_stdin      : false

        # setup handling of the results
        f = (mesg) =>
            if mesg.parent_header.msg_id == message.header.msg_id
                if mesg.content?.execution_state == 'idle'
                    @removeListener('iopub', f)
                opts.cb(undefined, misc.copy_with(mesg,['metadata', 'content', 'buffers']))
        @on('iopub', f)

        # send the message
        @_channels.shell.next(message)

    close: =>
        if @_state == 'closed'
            return
        if @_kernel?
            @_kernel.spawn.kill()
            fs.unlink(@_kernel.connectionFile)
            delete @_kernel
        # TODO -- clean up channels?
        @_state = 'closed'