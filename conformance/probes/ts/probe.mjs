import { debug, info, scope, success, trace } from '@adriangalilea/utils/log'

info('daemon starting')
const api = scope('api')
api.warn('upstream returned 502')
api.scope('auth').error('token expired')
success('ready')
// Below the default level: absence from the output is part of the check.
debug('connection pool warm')
trace('selector fired')
