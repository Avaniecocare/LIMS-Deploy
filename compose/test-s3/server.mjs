import { mkdirSync } from 'node:fs';
import S3rver from 's3rver';

mkdirSync('/data', { recursive: true });
await new S3rver({ port: 9000, address: '0.0.0.0', silent: true, directory: '/data', vhostBuckets: false, allowMismatchedSignatures: true, configureBuckets: [{ name: 'lims' }] }).run();
console.log('dev S3 listening on 9000');
