'use strict';
require('./rone-index-lib.cjs').run().catch(error => {
  console.error(`[R-ONE ${String(error.category || 'error').toUpperCase()} ERROR] ${error.message}`);
  process.exitCode = 1;
});
