## MODIFIED Requirements

### Requirement: CI rehearses restore finalization against a real database copy
For each supported PostgreSQL major, the required integration gate SHALL back up a populated disposable installation after management writes are quiesced and restore its DANS database and authoritative PowerDNS state into isolated copies. The rehearsal MUST keep DANS instances from serving the restored copies until the offline finalization command succeeds and the restored PowerDNS fixture's expected zones, metadata, and representative forward and PTR answers have been checked. The restored DANS service MUST use only the restored PowerDNS instance. The gate SHALL verify that existing identity, authorization, and audit data survive; every pre-restore credential captured by the rehearsal is rejected afterward; one replacement credential authenticates as the same enabled operator; and the finalized installation becomes ready for public API access. CI-visible output and artifacts MUST NOT contain backup bytes, credential values, or raw restore diagnostics.

#### Scenario: Restore and finalize a populated installation
- **WHEN** the gate restores paired backups containing an operator, another active token, authorization and audit history, and authoritative zones with records and metadata, then finalizes the DANS copy offline for the existing operator
- **THEN** the restored installation becomes ready with the same operator identity and preserved data, the replacement credential can use the public API, and the restored authoritative server answers the expected forward and PTR queries

#### Scenario: Restored credentials are invalidated
- **WHEN** the finalized installation receives any pre-restore credential captured by the rehearsal
- **THEN** it rejects that credential and does not restore its authority

#### Scenario: Restored management uses only restored DNS state
- **WHEN** an authorized write is made through the finalized restored DANS service
- **THEN** the restored authoritative server reflects the write and the original authoritative server does not

#### Scenario: Authoritative restore is missing or mismatched
- **WHEN** a required restored zone, record, or metadata item does not match the pre-backup fixture
- **THEN** the gate fails without starting a DANS instance against that restored copy or publishing confidential diagnostics

#### Scenario: Finalization does not complete
- **WHEN** offline finalization fails during the rehearsal
- **THEN** the gate fails without starting a DANS instance against that restored copy or publishing confidential diagnostics
