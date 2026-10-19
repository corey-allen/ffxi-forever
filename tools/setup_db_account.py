"""
FFXI-Forever: one-time MariaDB account setup for the local Phoenix server.

Creates the `xidb` database (utf8mb4 / utf8mb4_general_ci, matching Phoenix's
tools/dbtool.py) and a dedicated `xiforever` account limited to `xidb.*`,
then writes the generated password into the server's gitignored
settings/network.lua. Re-running rotates the password and keeps both in sync.

Run interactively from your own terminal (it prompts for the root password):
    py -3 E:\\Claude\\Projects\\FFXI-Forever\\tools\\setup_db_account.py

Nothing secret is printed, logged, or passed on a command line.
"""

import getpass
import os
import pathlib
import re
import secrets
import sys

import mariadb

SERVER_DIR = pathlib.Path(r"E:\FFXI-Forever\server")
NETWORK_LUA = SERVER_DIR / "settings" / "network.lua"
DB_NAME = "xidb"
DB_USER = "xiforever"
DB_HOSTS = ("localhost", "127.0.0.1")


def main() -> int:
    if not NETWORK_LUA.is_file():
        print(f"Missing {NETWORK_LUA}; copy settings/default/*.lua into settings/ first.")
        return 1

    text = NETWORK_LUA.read_text(encoding="utf-8")
    if not re.search(r"^\s*SQL_LOGIN\s*=\s*'" + DB_USER + "'", text, re.M):
        print(f"settings/network.lua SQL_LOGIN is not '{DB_USER}'; refusing to continue.")
        return 1

    # Non-interactive use: set FFXI_DB_ROOT_PASSWORD for this process only.
    root_pw = os.environ.pop("FFXI_DB_ROOT_PASSWORD", None) or getpass.getpass(
        "MariaDB root password (input hidden): "
    )
    try:
        conn = mariadb.connect(host="127.0.0.1", port=3306, user="root", password=root_pw)
    except mariadb.Error as err:
        print(f"Could not connect as root: {err}")
        return 1
    finally:
        root_pw = None

    # URL-safe alphabet: no quotes/backslashes, so it is safe inside SQL and Lua literals.
    app_pw = secrets.token_urlsafe(32)

    cur = conn.cursor()
    cur.execute(
        f"CREATE DATABASE IF NOT EXISTS `{DB_NAME}` "
        "CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci"
    )
    for host in DB_HOSTS:
        cur.execute(f"CREATE USER IF NOT EXISTS '{DB_USER}'@'{host}' IDENTIFIED BY '{app_pw}'")
        cur.execute(f"ALTER USER '{DB_USER}'@'{host}' IDENTIFIED BY '{app_pw}'")
        cur.execute(f"GRANT ALL PRIVILEGES ON `{DB_NAME}`.* TO '{DB_USER}'@'{host}'")
    cur.execute("FLUSH PRIVILEGES")
    conn.commit()
    conn.close()

    # Verify the new account works before touching the settings file.
    try:
        mariadb.connect(host="127.0.0.1", port=3306, user=DB_USER, password=app_pw, database=DB_NAME).close()
    except mariadb.Error as err:
        print(f"Account created but test login failed: {err}")
        return 1

    new_text, n = re.subn(
        r"^(\s*SQL_PASSWORD\s*=\s*)'[^']*'",
        lambda m: m.group(1) + "'" + app_pw + "'",
        text,
        count=1,
        flags=re.M,
    )
    if n != 1:
        print("Could not find SQL_PASSWORD in settings/network.lua; password NOT saved.")
        return 1
    NETWORK_LUA.write_text(new_text, encoding="utf-8")

    print(f"OK: database `{DB_NAME}` ready, account '{DB_USER}' verified, settings/network.lua updated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
