export default class Operation {
  constructor(operationId, spec) {
    this.id = operationId;
    this.done = false;
    this.err = null;
    this.req = {body: null, headers: {}};
    this.res = {body: {}, headers: {}};
    this.spec = spec;
    this.subscribers = [];
  }

  error() {
    return this.err || [];
  }

  fetchParams() {
    const req = {headers: this.headers};
    if (this.req.hasOwnProperty('body')) req.body = this.req.body;
    return req;
  }

  fulfill(res) {
    if (this.done) throw 'Already resolved.';
    this.done = true;
    this.res = res;
    this.subscribers.forEach(cb => cb(this));
    return this;
  }

  reject(err) {
    if (this.done) throw 'Already resolved.';
    this.done = true;
    this.err = Array.isArray(err) ? err : [{message: err}];
    this.subscribers.forEach(cb => cb(this));
    return this;
  }

  success() {
    return this.done && !this.err;
  }

  // This is required by https://svelte.dev/docs#svelte_store
  subscribe(cb) {
    this.subscribers.push(cb);
    cb(this);
    return () => this.subscribers.filter(i => (i != cb));
  }

  url() {
    return this.spec ? this._url || (this._url = new URL(this.spec.url)) : null;
  }
}