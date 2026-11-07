from patterns import CHECK, LAYOUT
old_check = "rc=0 ticks=64 in=238 out=256 overruns=0 p50=33770 p95=55218 p99=79755 max=79755 ns"
new_check = "rc=0 ticks=64 packets_in=238 datagrams_out=256 overruns=0 p50=33770ns p95=55218ns p99=79755ns max=79755ns"
old_lay = "clean 1: A cpus=0 p50=33713 p95=50123 p99=78540 max=80018 | B cpus=1 p50=22313 p95=30726 p99=55104 max=67575"
new_lay = "clean 1: A cpus=0 p50=33713ns p95=50123ns p99=78540ns max=80018ns | B cpus=1 p50=22313ns p95=30726ns p99=55104ns max=67575ns"
want_c = ("64", "0", "33770", "55218", "79755", "79755")
want_l = [("33713", "50123", "78540", "80018"), ("22313", "30726", "55104", "67575")]
for s in (old_check, new_check):
    m = CHECK.search(s); assert m and m.groups() == want_c, s
for s in (old_lay, new_lay):
    g = [m.groups() for m in LAYOUT.finditer(s)]; assert g == want_l, s
print("ok: 2 formats x 2 patterns parse to the same integers")
