"""The dedicated read-only database user behind every MCP client: created, granted, validated, posture-checked."""

from __future__ import annotations

from exakit.adapters.exapump import Exapump, Profile, has_token, temp_config
from exakit.adapters.fs.credentials import CredentialStore
from exakit.domain.errors import BadInput, Failed

from . import Context
from .runtime_ops import credentials, exapump



# --- the read-only user ----------------------------------------------------------


def _die_missing(what: str, ctx: Context) -> Failed:
    return Failed(f"The install record is incomplete (no {what} recorded), so the read-only login for your AI client cannot be created. "
                  f"Re-run the installer to rebuild it: {ctx.install_command()}", remedy=ctx.install_command())


def configure_readonly_access(ctx: Context) -> None:
    """Create or refresh the dedicated read-only user, grant, validate, and assert its posture."""
    manifest = ctx.manifest()
    pump = exapump(ctx)
    if pump is None:
        raise Failed("exapump is required for MCP read-only setup but was not found.", remedy="exakit update")
    host, port, admin_user, admin_password = _admin_login(ctx, manifest)
    ro_user, schema, ro_password = _readonly_identity(ctx)
    profiles = [Profile("admin", host, port, admin_user, admin_password),
                Profile("mcp_readonly", host, port, ro_user, ro_password, schema=schema)]
    with temp_config(ctx.paths.cache, profiles) as config:
        _provision(ctx, pump, config, ro_user, ro_password, schema)
        _validate_login(ctx, pump, config, ro_user)
        assert_readonly_posture(pump, config, ro_user, schema)
    _record_connection(ctx, ro_user, schema)
    ctx.ui.ok("Dedicated MCP read-only access is configured and validated")


def _admin_login(ctx: Context, manifest) -> tuple[str, int, str, str]:
    """(host, port, user, password) of the database admin from the install record; refuses an incomplete record."""
    admin_user = manifest.get("runtime.user")
    if not admin_user:
        raise _die_missing("database user", ctx)
    pw_file = manifest.get("runtime.password_file")
    admin_password = credentials(ctx).read(pw_file.rsplit("/", 1)[-1]) if pw_file else None
    if not admin_password:
        raise Failed("No runtime database password is available (runtime.password_file is missing). Re-run the installer to rebuild it.",
                     remedy=ctx.install_command())
    dsn = manifest.get("runtime.dsn") or ""
    host, _, port_text = dsn.rpartition(":")
    if not host or not port_text.isdigit():
        raise _die_missing("database address", ctx)
    return host, int(port_text), admin_user, admin_password


def _readonly_identity(ctx: Context) -> tuple[str, str, str]:
    """(user, default schema, password): the names from the environment, the password from the credential store."""
    ro_user = (ctx.env.get("EXAKIT_MCP_READONLY_USER") or ctx.catalog.kit.mcp_readonly_user).upper()
    if not ro_user.replace("_", "").isalnum():
        raise BadInput(f"Invalid EXAKIT_MCP_READONLY_USER: {ro_user}")
    schema = (ctx.env.get("EXAKIT_MCP_READONLY_SCHEMAS") or ctx.catalog.kit.mcp_readonly_schemas).split(",")[0].strip().upper()
    store = credentials(ctx)
    ro_password = store.read("mcp_readonly_password")
    if not CredentialStore.is_token(ro_password):
        ro_password = CredentialStore.new_token()
        store.store("mcp_readonly_password", ro_password)
    return ro_user, schema, ro_password


def _provision(ctx: Context, pump: Exapump, config, ro_user: str, ro_password: str, schema: str) -> None:
    """The admin SQL sequence: user present or created, password refreshed, session, schema, read grants."""
    def admin(sql: str):
        return pump.sql("admin", sql, config=config)

    def must(done, message: str) -> None:
        if not done.ok:
            ctx.log.line("ERROR", f"{message}: {done.err.strip()[-300:] or done.out.strip()[-300:]}")
            raise Failed(message, remedy="exakit mcp-setup")

    probe = admin(f"SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_USERS WHERE USER_NAME = '{ro_user}') "
                  "THEN 'EXAKIT_MCP_USER_PRESENT' ELSE 'EXAKIT_MCP_USER_MISSING' END AS STATUS")
    must(probe, "Could not read the database's user list.")
    if "EXAKIT_MCP_USER_PRESENT" not in probe.out:
        ctx.ui.info(f"Creating the dedicated MCP read-only database user ({ro_user.lower()})")
        must(admin(f"CREATE USER {ro_user} IDENTIFIED BY \"{ro_password}\""), "Could not create the MCP read-only database user.")
    must(admin(f"ALTER USER {ro_user} IDENTIFIED BY \"{ro_password}\""), "Could not refresh the MCP read-only database password.")
    must(admin(f"GRANT CREATE SESSION TO {ro_user}"), "Could not grant CREATE SESSION to the MCP read-only user.")
    schema_probe = admin(f"SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '{schema}') "
                         "THEN 'EXAKIT_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHEMA_MISSING' END AS STATUS")
    if "EXAKIT_SCHEMA_PRESENT" not in schema_probe.out:
        ctx.ui.info(f"Creating default schema {schema} for MCP-safe querying")
        must(admin(f"CREATE SCHEMA {schema}"), f"Could not create the default schema {schema}.")
    must(admin(f"GRANT USE ANY SCHEMA TO {ro_user}"), "Could not grant USE ANY SCHEMA to the MCP read-only user.")
    must(admin(f"GRANT SELECT ANY TABLE TO {ro_user}"), "Could not grant SELECT ANY TABLE to the MCP read-only user.")


def _validate_login(ctx: Context, pump: Exapump, config, ro_user: str) -> None:
    ctx.ui.info("Validating dedicated MCP read-only login")
    login = pump.sql("mcp_readonly", "SELECT CURRENT_USER AS EXAKIT_CURRENT_USER", config=config)
    if not login.ok or ro_user not in login.out.upper():
        raise Failed("The MCP read-only user could not log in with the generated credentials.", remedy="exakit mcp-setup")
    if not has_token(pump.sql("mcp_readonly", "SELECT 'EXAKIT_MCP_READONLY_OK' AS STATUS", config=config), "EXAKIT_MCP_READONLY_OK"):
        raise Failed("The MCP read-only user did not pass the validation query.", remedy="exakit mcp-setup")


def _record_connection(ctx: Context, ro_user: str, schema: str) -> None:
    store = credentials(ctx)

    def change(m) -> None:
        m.set("components.mcp_server.connection.user", ro_user.lower())
        m.set("components.mcp_server.connection.password_file", str(store.path("mcp_readonly_password")))
        m.set("components.mcp_server.connection.schemas", [schema])
        m.set("components.mcp_server.connection.default_schema", schema)
        m.set("components.mcp_server.connection.read_scope",
              "every schema (USE ANY SCHEMA + SELECT ANY TABLE); 'schemas' is the connection default, not a limit")
        m.set("components.mcp_server.connection.validated", True)
    ctx.manifest_store.update(change)


def assert_readonly_posture(pump: Exapump, config, ro_user: str, schema: str) -> None:
    """The six grant checks plus a live write probe; any failure stops setup to protect the database."""
    checks = [
        (f"SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE='{ro_user}' AND PRIVILEGE='CREATE SESSION') THEN 'EXAKIT_CREATE_SESSION_OK' ELSE 'MISSING' END", "EXAKIT_CREATE_SESSION_OK", "CREATE SESSION is not granted"),
        (f"SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE='{ro_user}' AND PRIVILEGE='USE ANY SCHEMA') THEN 'EXAKIT_USE_ANY_SCHEMA_OK' ELSE 'MISSING' END", "EXAKIT_USE_ANY_SCHEMA_OK", "USE ANY SCHEMA is not granted"),
        (f"SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE='{ro_user}' AND PRIVILEGE='SELECT ANY TABLE') THEN 'EXAKIT_SELECT_ANY_TABLE_OK' ELSE 'MISSING' END", "EXAKIT_SELECT_ANY_TABLE_OK", "SELECT ANY TABLE is not granted"),
        (f"SELECT CASE WHEN (SELECT COUNT(*) FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE='{ro_user}' AND PRIVILEGE NOT IN ('CREATE SESSION','USE ANY SCHEMA','SELECT ANY TABLE'))=0 THEN 'EXAKIT_SYS_PRIV_SCOPE_OK' ELSE 'EXTRA' END", "EXAKIT_SYS_PRIV_SCOPE_OK", "the read-only user holds extra system privileges"),
        (f"SELECT CASE WHEN (SELECT COUNT(*) FROM EXA_DBA_ROLE_PRIVS WHERE GRANTEE='{ro_user}' AND GRANTED_ROLE NOT IN ('PUBLIC'))=0 THEN 'EXAKIT_ROLE_SCOPE_OK' ELSE 'EXTRA' END", "EXAKIT_ROLE_SCOPE_OK", "the read-only user holds extra roles"),
        (f"SELECT CASE WHEN (SELECT COUNT(*) FROM EXA_DBA_OBJ_PRIVS WHERE GRANTEE='{ro_user}' AND PRIVILEGE <> 'SELECT')=0 THEN 'EXAKIT_OBJ_PRIV_SCOPE_OK' ELSE 'EXTRA' END", "EXAKIT_OBJ_PRIV_SCOPE_OK", "the read-only user holds non-SELECT object privileges"),
    ]
    for sql, token, problem in checks:
        if not has_token(pump.sql("admin", sql, config=config), token):
            raise Failed(f"Security check failed: {problem}. Setup stopped to protect your database.", remedy="exakit mcp-setup")
    probe = pump.sql("mcp_readonly", f"CREATE TABLE {schema}.EXAKIT_MCP_PERMISSION_PROBE (ID DECIMAL)", config=config)
    if probe.ok:
        pump.sql("admin", f"DROP TABLE {schema}.EXAKIT_MCP_PERMISSION_PROBE", config=config)
        raise Failed(f"Security check failed: the MCP read-only user was able to write to schema {schema}, but it must be read-only. "
                     "Setup stopped to protect your database.", remedy="exakit mcp-setup")
