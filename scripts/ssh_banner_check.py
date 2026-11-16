
import socket
import sys
from datetime import datetime


def get_ssh_banner(host, port=22, timeout=5):
    """Connect to an SSH server and read its banner."""
    try:
        with socket.create_connection((host, port), timeout=timeout) as connection:
            connection.settimeout(timeout)
            banner = connection.recv(1024).decode("utf-8", errors="replace")
            return banner.strip()
    except (OSError, TimeoutError) as error:
        return f"ERROR: {error}"


def main():
    print("=== SSH Banner Comparison Tool ===")
    print("Only test systems you have permission to access.\n")

    targets = []

    for number in range(1, 3):
        host = input(f"Enter IP address for system {number}: ").strip()
        port_text = input(
            f"Enter SSH port for system {number} (default 22): "
        ).strip()

        try:
            port = int(port_text) if port_text else 22

            if not 1 <= port <= 65535:
                raise ValueError

        except ValueError:
            print("Invalid port number.")
            sys.exit(1)

        targets.append((host, port))

    results = []

    for host, port in targets:
        print(f"\nChecking {host}:{port}...")
        banner = get_ssh_banner(host, port)
        print(f"SSH Banner: {banner}")
        results.append((host, port, banner))

    if any(result[2].startswith("ERROR:") for result in results):
        comparison = "Comparison unavailable: one or more connections failed."
    elif results[0][2] == results[1][2]:
        comparison = "Both systems returned the same SSH banner."
    else:
        comparison = "The systems returned different SSH banners."

    print(f"\nComparison: {comparison}")
    print("Note: SSH banners alone cannot confirm a honeypot.")

    with open("ssh_banner_results.txt", "w") as file:
        file.write("SSH Banner Comparison Results\n")
        file.write(
            f"Date: {datetime.now().isoformat(timespec='seconds')}\n\n"
        )

        for host, port, banner in results:
            file.write(f"{host}:{port} - {banner}\n")

        file.write(f"\n{comparison}\n")

    print("\nResults saved to ssh_banner_results.txt")


if __name__ == "__main__":
    main()

