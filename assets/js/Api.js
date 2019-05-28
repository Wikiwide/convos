import Operation from '../store/Operation';

export class Api {
  constructor(url, params = {}) {
    this.debug = params.debug;
    this.url = url;
    this.op = {};
  }

  async createOperation(operationId, params = {}) {
    await this.spec(); // Set up this.op

    const op = new Operation(operationId, this.op[operationId]);
    op.req.params = params;
    op.req.headers = {'Content-Type': 'application/json'};
    if (!op.url()) return op.reject('Invalid operationId.');

    (op.spec.parameters || []).forEach(p => {
      if (!this._hasProperty(params, p) && !p.required) {
        return;
      }
      else if (p.in == 'path') {
        const re = new RegExp('(%7B|\\{)' + p.name + '(%7D|\\})', 'i');
        op.url().pathname = op.url().pathname.replace(re, this._extractValue(params, p));
      }
      else if (p.in == 'query') {
        op.url().searchParams.set(p.name, this._extractValue(params, p));
      }
      else if (p.in == 'body') {
        op.req.body = this._extractValue(params, p);
      }
      else if (p.in == 'header') {
        op.req.header[p.name] = this._extractValue(params, p.name);
      }
      else {
        throw '[Api] Parameter in:' + p.in + ' is not supported.';
      }
    });

    return op;
  }

  async execute(operationId, params = {}) {
    const op = operationId.req ? operationId : this.createTx(operationId, params);
    if (op.done) return op;
    if (this.debug) console.log('[Api]', op);
    let res = await fetch(op.url(), op.fetchParams());
    op.res.body = await res.json();
    op.res.headers = res.headers;
    op.res.status = res.status;
    return op;
  }

  _extractValue(params, p) {
    if (p.schema && (params.tagName || '').toLowerCase() == 'form' ) {
      const body = {};
      Object.keys(p.schema.properties).forEach(k => { body[k] = params[k] && params[k].value });
      return JSON.stringify(body);
    }
    else if (params[p.name] && params[p.name].tagName) {
      return params[p.name].value;
    }
    else if (p.schema) {
      const body = {};
      Object.keys(p.schema.properties).forEach(k => { body[k] = params[k] });
      return JSON.stringify(body);
    }
    else {
      return params[p.name];
    }
  }

  _hasProperty(params, p) {
    if (p.in == 'body') {
      return true;
    }
    else if ((params.tagName || '').toLowerCase() == 'form') {
      return params[p.name] ? true : false;
    }
    else {
      return params.hasOwnProperty(p.name);
    }
  }

  async spec() {
    if (this._spec) return this._spec;

    const res = await fetch(this.url);
    const api = await res.json();

    Object.keys(api.paths).forEach(path => {
      Object.keys(api.paths[path]).forEach(method => {
        const op = api.paths[path][method];
        const operationId = op.operationId;
        if (!operationId) return;

        op.method = method.toUpperCase();
        op.url = api.schemes[0] + '://' + api.host + api.basePath + path;
        op.parameters = (op.parameters || []).map(p => {
          if (!p['$ref']) return p;
          const refPath = p['$ref'].replace(/^\#\//, '').split('/');
          let ref = api;
          while (refPath.length) ref = ref[refPath.shift()];
          return ref;
        });

        this.op[operationId] = op;
      });
    });

    return (this._spec = api);
  }
}
