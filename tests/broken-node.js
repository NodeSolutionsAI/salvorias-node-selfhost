// Test fixture for the upgrade-rollback step in tests/e2e-in-vm.sh: a real
// ELF executable (once built with bun, see tests/README.md) that passes the
// installer's version check, then fails as a daemon.
if (process.argv[2] === 'version') {
  console.log('salvorias-node v0.0.10-broken');
  process.exit(0);
}
console.error('broken build: refusing to start');
process.exit(1);
