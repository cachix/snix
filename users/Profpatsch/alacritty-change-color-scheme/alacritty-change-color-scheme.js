'use strict';
//@ts-check

// Step 3: Create the script
const dbus = require('dbus-native');
const fs = require('fs');
const assert = require('assert');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const {
  BasicTracerProvider,
  BatchSpanProcessor,
  ConsoleSpanExporter,
  SimpleSpanProcessor,
} = require('@opentelemetry/sdk-trace-base');
const opentelemetry = require('@opentelemetry/api');
const { hrTime } = require('@opentelemetry/core');
const { AsyncHooksContextManager } = require('@opentelemetry/context-async-hooks');
const { EventEmitter } = require('stream');
const { setTimeout } = require('node:timers/promises');
const { promisify } = require('util');
const { pseudoRandomBytes } = require('crypto');
const { execFile } = require('node:child_process');
const { readdir, realpath, access } = require('fs/promises');

// NB: this code is like 80% copilot generated, and seriously missing error handling.
// It might break at any time, but for now it seems to work lol.

const programName = process.argv[1];
let themeDir = process.argv[2];
// read the dark alacritty theme file as first argument
let darkThemeName = process.argv[3] ?? 'alacritty_0_12';
// read the light alacritty theme file as second argument
let lightThemeName = process.argv[4] ?? 'dayfox';
assert(themeDir, 'Theme directory is required');

let darkTheme = getThemePathSync(darkThemeName);
let lightTheme = getThemePathSync(lightThemeName);

console.log(`Dark theme: ${darkTheme}`);
console.log(`Light theme: ${lightTheme}`);

class Bus {
  /**
   * @param {'session' | 'system'} type
   * @param {string} name
   */
  constructor(name, type) {
    this._name = name;
    this._type = type;
    switch (type) {
      case 'session':
        this._bus = dbus.sessionBus();
        break;
      case 'system':
        this._bus = dbus.systemBus();
        break;
    }
    this._bus.connection.once(
      'error',
      /** @param {Error} err */
      err => {
        console.error(`${this._type} bus ${this._name} error: ${err}`);
        throw new Error(`${this._type} bus ${this._name} error: ${err}`);
      },
    );
    this._bus.connection.once('end', () => {
      console.error(`${this._type} bus ${this._name} connection ended unexpectedly`);
      throw new Error(`${this._type} bus ${this._name} connection ended unexpectedly`);
    });
  }

  /**
   * @param {string} what
   */
  _busErrorMessages(what) {
    return `Error getting ${what} from ${this._type} bus ${this._name}`;
  }

  /**
   *
   * @param {string} name
   * @param {number} flags
   * @returns {Promise<number>}
   */
  requestName(name, flags) {
    return promisifyMethodAnnotate(
      this._bus,
      // @ts-ignore
      this._bus.requestName,
      this._busErrorMessages(`requesting name ${name}`),
      name,
      flags,
    );
  }

  /**
   * @param {{ [key: string]: unknown }} iface
   * @param {string} path
   * @param {{ name: string; methods: { [key: string]: unknown }; }} opts
   */
  exportInterface(iface, path, opts) {
    // @ts-ignore
    return this._bus.exportInterface(iface, path, opts);
  }

  /**
  /** Get object from bus, with the given interface (not checked!)
   * @template {{[key: string]: (...args: any[]) => Promise<unknown>}} Interface
   * @param {string} serviceName
   * @param {string} interfaceName
   * @param {string} objectName object name
   * @returns {Promise<Interface & EventEmitter >}
   */
  async getObject(serviceName, interfaceName, objectName) {
    //@ts-ignore
    const s = this._bus.getService(serviceName);

    /** @type {{[key: string]: Function}} */
    // @ts-ignore
    const iface = await promisifyMethodAnnotate(
      s,
      s.getInterface,
      this._busErrorMessages(`interface ${interfaceName}`),
      objectName,
      interfaceName,
    );

    if (!iface) {
      throw new Error(
        `Interface ${interfaceName} not found on object ${objectName} of service ${serviceName}`,
      );
    }

    // We need to promisify all methods on the interface
    const methodNames = Object.keys(iface.$methods ?? {});
    /** @type {{[key: string]: any}} */
    const methods = {};
    /** @type {Record<string, Function>} */
    for (const methodName of methodNames) {
      methods[methodName] = iface[methodName];
      iface[methodName] = (/** @type {any[]} */ ...args) =>
        promisifyMethodAnnotate(
          iface,
          methods[methodName],
          this._busErrorMessages(`method ${methodName}`),
          ...args,
        );
    }

    // @ts-ignore
    return iface;
  }
}

// Connect to the user session bus
const bus = new Bus('color-scheme', 'session');

opentelemetry.diag.setLogger({ ...console, verbose: console.log });

const exporter = new OTLPTraceExporter();
const consoleExporter = new ConsoleSpanExporter();
const provider = new BasicTracerProvider({
  //@ts-ignore
  resource: {
    attributes: {
      'service.name': 'alacritty-change-color-scheme',
      // 'service.namespace': 'default',
      // 'service.instance.id': 'alacritty-change-color-scheme-01',
      // 'service.version': '0.0.1',
    },
  },
  spanProcessors: [
    // new BatchSpanProcessor(exporter, {
    //   maxQueueSize: 100,
    //   scheduledDelayMillis: 5000,
    // }),
    new SimpleSpanProcessor(exporter),
    new SimpleSpanProcessor(consoleExporter),
  ],
});
provider.register({
  contextManager: new AsyncHooksContextManager().enable(),
});

const dbusSpanEmitter = new EventEmitter();

dbusSpanEmitter.on('new-root-span', onNewRootSpan);

/** @typedef {{spanId: string, name: string, parentId?: string, startTime?: opentelemetry.TimeInput, attributes?: opentelemetry.Attributes}} StartSpan */
/** @typedef {{spanId: string, endTime?: opentelemetry.TimeInput}} EndSpan */

/** @param {opentelemetry.Tracer} tracer,
 *  @param {StartSpan} spanData */
function emitNewRootSpanEvent(tracer, spanData) {
  dbusSpanEmitter.emit('new-root-span', tracer, spanData);
}

/**
 * @param {StartSpan} childSpanData
 * @param {string} parentSpanId
 */
function emitNewChildSpanEvent(parentSpanId, childSpanData) {
  dbusSpanEmitter.emit(`new-child-span-for/${parentSpanId}`, childSpanData);
}

/** @param {EndSpan} endSpanData */
function emitEndSpanEvent(endSpanData) {
  dbusSpanEmitter.emit(`end-span-for/${endSpanData.spanId}`, endSpanData);
}

/** @param {opentelemetry.Tracer} tracer
 *  @param {StartSpan} spanData */
function onNewRootSpan(tracer, spanData) {
  console.log(`New span: ${spanData.spanId}`);
  setupActiveSpan(tracer, spanData);
}

/** @param {opentelemetry.Tracer} tracer
 *  @param {StartSpan} spanData */
function setupActiveSpan(tracer, spanData) {
  const SPAN_TIMEOUT = 1_000_000; // 1000 seconds
  const SPAN_TIMEOUT_SHORT = 10_000; // 10 seconds
  if (typeof spanData.startTime === 'number') {
    console.warn(
      'startTime is a number, not a hrTime tuple. This would use perfomance.now() in the wrong context, so we are ignoring it.',
    );
    spanData.startTime = undefined;
  }
  tracer.startActiveSpan(
    spanData.name,
    { startTime: spanData.startTime, attributes: spanData.attributes },
    span => {
      let activeContext = opentelemetry.context.active();

      /** @param {{spanId: string, name: string}} childSpanData */
      function onNewChildSpan(childSpanData) {
        opentelemetry.context.with(activeContext, () => {
          console.log(`New child span: ${childSpanData.spanId}`);
          setupActiveSpan(tracer, childSpanData);
        });
      }
      dbusSpanEmitter.on(`new-child-span-for/${spanData.spanId}`, onNewChildSpan);

      const removeTimeoutOnEnd = new AbortController();

      /** @param {{endTime?: opentelemetry.TimeInput}} endSpanData */
      function onEndSpan(endSpanData) {
        opentelemetry.context.with(activeContext, () => {
          console.log(`End span: ${spanData.spanId}`);
          if (typeof endSpanData.endTime === 'number') {
            console.warn(
              'endTime is a number, not a hrTime tuple. This would use perfomance.now() in the wrong context, so we are ignoring it.',
            );
            endSpanData.endTime = undefined;
          }
          span.end(endSpanData.endTime);
          // we don’t remove the child span listener here, because in theory child spans don’t have to be inside parent spans.
          // However, we only want to keep the child span listener around for a little more, so let’s set a shorter timeout here
          setTimeout(SPAN_TIMEOUT_SHORT).then(() => {
            dbusSpanEmitter.off(`new-child-span-for/${spanData.spanId}`, onNewChildSpan);
          });
          // remove the general long timeout belove
          removeTimeoutOnEnd.abort();
        });
      }
      dbusSpanEmitter.once(`end-span-for/${spanData.spanId}`, onEndSpan);

      // don't keep spans contexts open forever if we never get a second message
      // but we don’t end the spans, just remove the listeners.
      setTimeout(SPAN_TIMEOUT, undefined, { signal: removeTimeoutOnEnd.signal })
        .then(() => {
          console.warn(
            `Timeout for span ${spanData.spanId}, removing all event listeners`,
          );
          dbusSpanEmitter.off(`new-child-span-for/${spanData.spanId}`, onNewChildSpan);
          dbusSpanEmitter.off(`end-span-for/${spanData.spanId}`, onEndSpan);
        })
        .catch(err => {
          if (err.name === 'AbortError') {
            // console.log(`Timeout for span ${spanData.spanId} was aborted`);
          } else {
            throw err;
          }
        });
    },
  );
}

// set XDG_CONFIG_HOME if it's not set
if (!process.env.XDG_CONFIG_HOME) {
  process.env.XDG_CONFIG_HOME = process.env.HOME + '/.config';
}

/** get the path of the theme config file synchronously
 *
 * @param {string} theme
 * @returns {string}
 * */
function getThemePathSync(theme) {
  const path = `${themeDir}/${theme}.toml`;
  const absolutePath = fs.realpathSync(path);
  assert(fs.existsSync(absolutePath), `Theme file not found: ${absolutePath}`);
  return absolutePath;
}

/** get the path of the theme config file
 *
 * @param {string} theme
 * @returns {Promise<string | null>} null if the theme file does not exist
 * */
async function getThemePath(theme) {
  const path = `${themeDir}/${theme}.toml`;
  try {
    const absolutePath = await realpath(path);
    await access(absolutePath);
    return absolutePath;
  } catch (err) {
    return null;
  }
}

/** write new color scheme
 *
 * @param {'prefer-dark' | 'prefer-light'} cs
 */
function writeAlacrittyColorConfig(cs) {
  const theme = cs === 'prefer-dark' ? darkTheme : lightTheme;
  console.log(`
    Writing color scheme ${cs} with theme ${theme}`);
  fs.writeFileSync(
    process.env.XDG_CONFIG_HOME + '/alacritty/alacritty-colors-autogen.toml',
    `# !! THIS FILE IS GENERATED BY ${programName}
general.import = ["${theme}"]`,
    'utf8',
  );
}

/** Typescript type that returns the inner value type T from a Promise<T>
 * type PromiseVal<T> = T extends Promise<infer U> ? U : T;
 * @template T
 * @typedef {T extends Promise<infer U> ? U : T } PromiseVal
 */

/**
 * @template {{[key: string]: (...args: any[]) => Promise<unknown>}} T
 * @typedef {typeof Bus.prototype.getObject<T>} GetObject<T>
 */

/**
 * @template {{[key: string]: (...args: any[]) => Promise<unknown>}} T
 * @typedef {PromiseVal<ReturnType<GetObject<T>>>} IfaceReturn<T> */

/** get the current value of the color scheme from dbus
 *
 * @returns {Promise<'prefer-dark' | 'prefer-light'>}
 */
async function getColorScheme() {
  /** @typedef {{ReadOne: (interface: string, settingName: string) => Promise<[unknown, ['prefer-dark' | 'prefer-light']]>}} ColorScheme */
  /** @type {IfaceReturn<ColorScheme>} */
  let iface = await bus.getObject(
    'org.freedesktop.portal.Desktop',
    'org.freedesktop.portal.Settings',
    '/org/freedesktop/portal/desktop',
  );

  const [_, [value]] = await iface.ReadOne('org.gnome.desktop.interface', 'color-scheme');
  assert(value === 'prefer-dark' || value === 'prefer-light');
  return value;
}

/** promisify an object method and annotate any errors that get thrown
 * @template {Function} A
 * @param {object} obj
 * @param {A} method
 * @param {string} msg
 * @param  {...any} args
 * @returns {Promise<ReturnType<A>>}
 */
function promisifyMethodAnnotate(obj, method, msg, ...args) {
  return promisify(method.bind(obj))(...args).catch(annotateErr(msg));
}

/** write respective alacritty config if the colorscheme changes.
 * Colorscheme changes are only tracked in-between calls to this function in-memory.
 *
 * @param {'prefer-dark' | 'prefer-light'} cs
 */
function writeAlacrittyColorConfigIfDifferent(cs) {
  // only change the color scheme if it's different from the previous one
  let previous = null;
  if (previous === cs) {
    console.log(`Color scheme already set to ${cs}`);
    return;
  }
  previous = cs;

  console.log(`Color scheme changed to ${cs}`);
  writeAlacrittyColorConfig(cs);
}

/** Listen on the freedesktop SettingChanged dbus interface for the color-scheme setting to change. */
async function listenForColorschemeChange() {
  /** @type {PromiseVal<ReturnType<typeof bus.getObject<{}>>>} */
  const iface = await bus.getObject(
    'org.freedesktop.portal.Desktop',
    'org.freedesktop.portal.Settings',
    '/org/freedesktop/portal/desktop',
  );

  // Listen for SettingChanged signals
  iface.on('SettingChanged', (interfaceName, key, [_, [newValue]]) => {
    if (interfaceName === 'org.gnome.desktop.interface' && key == 'color-scheme') {
      writeAlacrittyColorConfigIfDifferent(newValue);
    }
  });

  console.log('Listening for color scheme changes...');
}

/** Create a dbus service that binds against the interface de.profpatsch.alacritty.ColorScheme and implements the method SetColorScheme */
async function exportColorSchemeDbusInterface() {
  console.log('Exporting color scheme interface de.profpatsch.alacritty.ColorScheme');
  const ifaceName = 'de.profpatsch.alacritty.ColorScheme';
  const iface = {
    name: 'de.profpatsch.alacritty.ColorScheme',
    methods: {
      SetColorScheme: ['s', ''],
      // first argument: 'dark' | 'light'
      // second argument: the theme name (one of the themes in the theme directory)
      // will only be applied during the run-time of this program, and reset on restart
      SetColorSchemeTheme: ['ss', ''],
    },
  };

  const ifaceImpl = {
    /** @type {function('prefer-dark' | 'prefer-light'): void} */
    SetColorScheme: function (cs) {
      console.log(`SetColorScheme called with ${cs}`);
      writeAlacrittyColorConfigIfDifferent(cs);
    },
    SetColorSchemeTheme: async function (
      /** @type {string} */ cs,
      /** @type {string} */ theme,
    ) {
      console.log(`SetColorSchemeTheme called with ${cs} and theme ${theme}`);
      if (cs !== 'dark' && cs !== 'light') {
        console.warn(`Invalid color scheme ${cs}`);
        return;
      }
      const themePath = await getThemePath(theme);
      if (themePath === null) {
        console.warn(`Theme ${theme} not found`);
        return;
      }
      if (cs === 'dark') {
        darkTheme = themePath;
      }
      if (cs === 'light') {
        lightTheme = themePath;
      }
      console.log(`Setting color scheme ${cs} with theme ${themePath}`);
      writeAlacrittyColorConfig(cs === 'dark' ? 'prefer-dark' : 'prefer-light');
    },
  };

  try {
    bus;
    const retCode = await bus.requestName(ifaceName, 0);
    console.log(
      `Request name returned ${retCode} for interface de.profpatsch.alacritty.ColorScheme`,
    );
    bus.exportInterface(ifaceImpl, '/de/profpatsch/alacritty/ColorScheme', iface);
    console.log('Exported interface de.profpatsch.alacritty.ColorScheme');
  } catch (err) {
    console.log('Error exporting interface de.profpatsch.alacritty.ColorScheme');
    console.error(err);
  }
}

/** Annotate an error as a promise .catch handler (rethrows the annotated error)
 * @param {string} msg
 * @returns {function(Error): void}
 */
function annotateErr(msg) {
  return err => {
    msg = err.message ? `${msg}: ${err.message}` : msg;
    err.message = msg;
    throw err;
  };
}

const bus2 = new Bus('otel', 'session');
async function exportOtelInterface() {
  console.log('Exporting OpenTelemetry interface');

  try {
    const retCode = bus2.requestName('de.profpatsch.otel.Tracer', 0);
    console.log(
      `Request name returned ${retCode} for interface de.profpatsch.otel.Tracer`,
    );

    const traceIface = {
      name: 'de.profpatsch.otel.Tracer',
      methods: {
        // These both just take a json string as input
        StartSpan: ['s', ''],
        EndSpan: ['s', ''],
        // An array of [(isStartSpan: bool, span: Span)]
        // So that you don’t have to call dbus for every span
        BatchSpans: ['a(bs)', ''],
      },
    };
    /** @type {(arg: {tracer: opentelemetry.Tracer, tracerName: string}) => {StartSpan: (input: string) => void, EndSpan: (input: string) => void, BatchSpans: (input: [boolean, string][]) => void }} */
    const traceImpl = tracer => ({
      StartSpan: function (input) {
        // TODO: actually verify json input
        /** @type {StartSpan} */
        const spanArgs = JSON.parse(input);
        if (spanArgs.parentId === undefined) {
          console.log(
            `Tracing root span ${spanArgs.name} with tracer ${tracer.tracerName}`,
          );
          emitNewRootSpanEvent(tracer.tracer, spanArgs);
        } else {
          console.log(
            `Tracing child span ${spanArgs.name} with tracer ${tracer.tracerName}`,
          );
          emitNewChildSpanEvent(spanArgs.parentId, spanArgs);
        }
      },
      EndSpan: function (input) {
        // TODO: actually verify json input
        /** @type {EndSpan} */
        const spanArgs = JSON.parse(input);
        console.log(`Ending span ${spanArgs.spanId} with tracer ${tracer.tracerName}`);
        emitEndSpanEvent(spanArgs);
      },
      BatchSpans: function (input) {
        // lol
        for (const [isStartSpan, span] of input) {
          if (isStartSpan) {
            traceImpl(tracer).StartSpan(span);
          } else {
            traceImpl(tracer).EndSpan(span);
          }
        }
      },
    });
    bus2.exportInterface(
      {
        /** @param {string} tracerName */
        CreateTracer: function (tracerName) {
          console.log(`Creating tracer with name ${tracerName}`);
          const tracer = opentelemetry.trace.getTracer(tracerName, '0.0.1');
          bus2.exportInterface(
            traceImpl({ tracer, tracerName }),
            `/de/profpatsch/otel/tracers/${tracerName}`,
            traceIface,
          );
          return `/de/profpatsch/otel/tracers/${tracerName}`;
        },
      },
      '/de/profpatsch/otel/TracerFactory',
      {
        name: 'de.profpatsch.otel.TracerFactory',
        methods: {
          CreateTracer: ['s', 's'],
        },
      },
    );
    console.log('Exported interface de.profpatsch.otel.TracerFactory');
  } catch (err) {
    console.log('Error exporting interface de.profpatsch.alacritty.ColorScheme');
    console.error(err);
  }
}

/** Returns the callsite of the function calling `getParentCallsite`, if any. */
async function getParentCallsite() {
  const getCallsites = (await import('callsites')).default;
  const cs = getCallsites();
  return cs[2] ?? cs[1] ?? null;
}

/** @typedef  {([true, StartSpan] | [false, EndSpan])} BatchSpan */

/**
 * @typedef {{
 *   StartSpan: (spanData: StartSpan) => Promise<void>,
 *   EndSpan: (spanData: EndSpan) => Promise<void>,
 *   BatchSpans: (spans: BatchSpan[]) => Promise<void>
 *  }} TracerIface
 */

/** Calls the tracer dbus interface, sets up a tracer
 *
 * @param {string} tracerName The name of the tracer to set up
 * @returns {Promise<TracerIface>}
 */
async function setupTracer(tracerName) {
  const parentCallsite = await getParentCallsite();
  console.log(`Setting up tracer ${tracerName} from ${parentCallsite?.getFileName()}`);

  /** @typedef {{CreateTracer: (name: string) => Promise<string>}} TracerFactory */
  /** @type {IfaceReturn<TracerFactory>} */
  const iface = await bus2.getObject(
    'de.profpatsch.otel.Tracer',
    'de.profpatsch.otel.TracerFactory',
    '/de/profpatsch/otel/TracerFactory',
  );
  const path = await iface.CreateTracer(tracerName);

  /**
   *  @typedef {{
   *    StartSpan: (spanData: string) => Promise<void>,
   *    EndSpan: (spanData: string) => Promise<void>
   *    BatchSpans: (spans: [boolean, string][]) => Promise<void>
   * }} Tracer
   *  @type {IfaceReturn<Tracer>}
   * */
  const tracerIface = await bus2.getObject(
    'de.profpatsch.otel.Tracer',
    'de.profpatsch.otel.Tracer',
    path,
  );

  /** @param {StartSpan} spanData */
  function StartSpan(spanData) {
    return tracerIface.StartSpan(JSON.stringify(spanData));
  }
  /**
   * @param {any} spanData
   */
  function EndSpan(spanData) {
    return tracerIface.EndSpan(JSON.stringify(spanData));
  }
  /** @param {[boolean, unknown][]} spans */
  function BatchSpans(spans) {
    return tracerIface.BatchSpans(
      spans.map(([isStartSpan, span]) => [isStartSpan, JSON.stringify(span)]),
    );
  }
  return {
    StartSpan,
    EndSpan,
    BatchSpans,
  };
}

/** @typedef {{}} Span */
/** @typedef {{name: string, attributes?: opentelemetry.Attributes, parentSpan?: Span}} SpanData */

class Tracer {
  /** @param {string} tracerName */
  static async setup(tracerName) {
    const iface = await setupTracer(tracerName);
    return new Tracer(tracerName, iface);
  }

  /**
   * @param {string} tracerName
   * @param {TracerIface} iface
   */
  constructor(tracerName, iface) {
    this.tracerName = tracerName;

    const batch = new EventEmitter();
    /**
     * @type {BatchSpan[]}
     */
    const batchQueue = [];

    async function sendBatch() {
      if (batchQueue.length > 0) {
        await iface.BatchSpans(batchQueue);
        batchQueue.length = 0;
      }
    }

    /**
     * @param {StartSpan} spanData
     */
    function onNewSpan(spanData) {
      batchQueue.push([true, spanData]);
      if (batchQueue.length > 10) {
        sendBatch();
      }
    }

    /**
     * @param {EndSpan} spanData
     */
    function onEndSpan(spanData) {
      batchQueue.push([false, spanData]);
      if (batchQueue.length > 10) {
        sendBatch();
      }
    }

    batch.on('new-span', onNewSpan);
    batch.on('end-span', onEndSpan);

    let errorCounter = 0;
    async function batchTimeout() {
      const BATCH_TIMEOUT = 100;
      try {
        await setTimeout(BATCH_TIMEOUT);
        await sendBatch();
      } catch (e) {
        errorCounter++;
        throw e;
      } finally {
        if (errorCounter > 5) {
          console.warn('Too many errors, stopping batchTimeout');
          throw new Error('Too many errors, had to stop batchTimeout');
        }
        await setTimeout(BATCH_TIMEOUT).then(batchTimeout);
      }
    }
    batchTimeout();
    /** @param {StartSpan} spanData */
    function startSpan(spanData) {
      batch.emit('new-span', spanData);
    }
    /** @param {EndSpan} spanId */
    function endSpan(spanId) {
      batch.emit('end-span', { spanId });
    }

    this.batch = {
      startSpan,
      endSpan,
    };
  }

  /**
   * @template A
   * @param {SpanData} spanData
   * @param {function(Span): A} f
   */
  async withSpan(spanData, f) {
    const spanId = this.tracerName + '-' + pseudoRandomBytes(16).toString('hex');
    const startTime = hrTime();
    // @ts-ignore spanId is an internal impl detaul to our Span type
    const parentId = spanData.parentSpan?.spanId;
    try {
      this.batch.startSpan({
        spanId,
        name: spanData.name,
        attributes: spanData.attributes,
        startTime,
        parentId,
      });
      const span = { spanId };
      return await f(span);
    } finally {
      this.batch.endSpan({ spanId });
    }
  }
}

const execFileP = promisify(execFile);

/** actual brightness roughly (but not quite arghhhh) logarithmic on a ThinkPad T14s with effin ARM crap
/* @type {number[]}
*/
const brightnessMappingInternal = [0, 2, 4, 6, 9, 14, 20, 35, 50, 84, 120, 147, 200, 255];
const brightnessMappingExternal = [0, 0, 0, 0, 12, 24, 36, 48, 60, 72, 84, 100, 100, 100];
const maxBrightnessVal = brightnessMappingInternal.length - 1;
async function getInitialInternalMonitorBrightness() {
  const { stdout } = await execFileP(`blight`, [`get`, 'brightness'], {});
  const brightness = parseInt(stdout, 10);

  const brightnessVal = brightnessMappingInternal.findIndex(value => value >= brightness);
  return brightnessVal;
}

/**
 * @param {number} brightnessVal number between 0 and `maxBrightnessVal`
 * (the amount of steps we want) where 0 is “turn off if possible” and `maxBrightnessVal` is “full brightness”
 * The steps should be roughly aligned (by human eye) between the internal and external monitor.
 */
async function SetBrightnessAllMonitors(brightnessVal) {
  return Promise.all([
    (async () => {
      const internalMonitorBrightness = brightnessMappingInternal[brightnessVal] ?? '255';
      // set the brightness for internal monitor with the `blight` command line util
      console.log(`Setting internal monitor brightness to ${internalMonitorBrightness}`);
      await execFileP(`blight`, [`set`, `${internalMonitorBrightness}`], {});
    })(),
    (async () => {
      // find external monitors by listing all directories in /dev/bus/ddcci and reading their numbers
      // external monitor brightness (ddc) is between 0 and 100
      const externalBrightness = brightnessMappingExternal[brightnessVal] ?? '100';
      ddcutilNewBrightness(externalBrightness);
    })(),
  ]);
}

const ddcutilEmitter = new EventEmitter();
/**
 * @param {number} brightness
 */
function ddcutilNewBrightness(brightness) {
  ddcutilEmitter.emit('new-brightness', brightness);
}

/**
 * @type {number | null}
 */
let nextBrightness = null;
/** Set the brightness of the external monitor using ddcutil,
 * but only if nothing else is already trying to set it. In that case schedule to set it later.
 * Also debounce the brightness setting to avoid setting it multiple times in a short time.
 *
 * @param {number} externalBrightness
 */
async function onDdcutilBrightnessChange(externalBrightness) {
  if (nextBrightness === externalBrightness) return;
  if (nextBrightness !== null) {
    nextBrightness = externalBrightness;
    console.log(`Already running, will set brightness to ${externalBrightness} later`);
    return;
  }
  nextBrightness = externalBrightness;

  // debounce for some ms if anything happens to nextBrightness in the meantime, use that value
  await setTimeout(250);
  if (nextBrightness !== externalBrightness) {
    console.log(
      `Newer brightness value ${nextBrightness} was requested, ignoring ${externalBrightness}`,
    );
    const brightness = nextBrightness;
    nextBrightness = null;
    await onDdcutilBrightnessChange(brightness);
    return;
  }

  const ddcciDevices = await readdir('/dev/bus/ddcci');
  console.log(`Found ddcci devices: ${ddcciDevices}`);

  for (const device of ddcciDevices) {
    console.log(
      `Setting external monitor brightness to ${externalBrightness} for device ${device}`,
    );

    await execFileP('ddcutil', [
      `--bus`,
      device,
      `--sleep-multiplier`,
      '0.20',
      `setvcp`,
      `0x10`,
      `${externalBrightness}`,
    ]).catch(err => {
      /** @type {string} */
      let stdout = err.stdout;
      // err.stdout contains "No monitor detected on bus"
      if (stdout.includes('No monitor detected on bus')) {
        console.log(`External monitor on bus ${device} is gone, ignoring.`);
        return;
      }
      console.warn(`Error setting brightness with ddcutil for device ${device}`, err);
    });
  }

  if (nextBrightness !== externalBrightness) {
    const brightness = nextBrightness;
    nextBrightness = null;
    await onDdcutilBrightnessChange(brightness);
  } else {
    nextBrightness = null;
    console.log(`Finished setting external monitor brightness to ${externalBrightness}`);
  }
}

async function exportDisplayBrightnessDbusInterface() {
  console.log('Exporting display brightness interface de.profpatsch.DisplayBrightness');
  const ifaceName = 'de.profpatsch.DisplayBrightness';
  const iface = {
    name: 'de.profpatsch.DisplayBrightness',
    methods: {
      // between 0 and 10
      SetBrightnessAllMonitors: ['d', ''],
      // either '+' or '-'
      SetBrightnessAllMonitorsRelative: ['s', ''],
    },
  };

  let currentBrightness = await getInitialInternalMonitorBrightness();
  console.log(`Current brightness: ${currentBrightness}`);

  ddcutilEmitter.on('new-brightness', onDdcutilBrightnessChange);

  const ifaceImpl = {
    /** @type {function(number): void} */
    SetBrightnessAllMonitors: function (brightness) {
      console.log(`SetBrightnessAllMonitors called with ${brightness}`);
      // set the brightness
      SetBrightnessAllMonitors(brightness);
    },

    /** @type {function(string): void} */
    SetBrightnessAllMonitorsRelative: function (direction) {
      console.log(`SetBrightnessAllMonitorsRelative called with ${direction}`);
      switch (direction) {
        case '+':
          currentBrightness = Math.min(maxBrightnessVal, currentBrightness + 1);
          break;
        case '-':
          currentBrightness = Math.max(0, currentBrightness - 1);
          break;
        default:
          console.warn(`Invalid direction ${direction}`);
          return;
      }
      ifaceImpl.SetBrightnessAllMonitors(currentBrightness);
    },
  };

  try {
    const retCode = await bus.requestName(ifaceName, 0);
    console.log(
      `Request name returned ${retCode} for interface de.profpatsch.DisplayBrightness`,
    );
    bus.exportInterface(ifaceImpl, '/de/profpatsch/DisplayBrightness', iface);
    console.log('Exported interface de.profpatsch.DisplayBrightness');
  } catch (err) {
    console.log('Error exporting interface de.profpatsch.DisplayBrightness');
    console.error(err);
  }
}

async function main() {
  await exportOtelInterface();
  await exportDisplayBrightnessDbusInterface();

  const tracer = await Tracer.setup('hello');
  await tracer.withSpan(
    {
      name: 'hello',
      attributes: {
        foo: 'bar',
      },
    },
    async span => {
      await tracer.withSpan(
        {
          parentSpan: span,
          name: 'world',
          attributes: {
            bar: 'baz',
          },
        },
        async () => {
          // Code inside the nested span
        },
      );
      // Code after the nested span
    },
  );

  await exportColorSchemeDbusInterface();

  // get the current color scheme
  const currentColorScheme = await getColorScheme();
  console.log(`Current color scheme: ${currentColorScheme}`);

  // write the color scheme
  writeAlacrittyColorConfig(currentColorScheme);

  // listen for color scheme changes
  await listenForColorschemeChange();
}

main().catch(err => {
  console.error(err);
});
