# Run 2 of ring-compare: p99 in ns, 8 clean runs per cell. Same CI runner as run 1 (per iFire). Planted defect caught 8 of 8 in every cell.
import numpy as np
plain_64 = [657687, 651796, 698764, 655883, 677104, 676963, 660573, 655317]
ring_64 = [795494, 715876, 686109, 685699, 668588, 699556, 683426, 664725]
sqpoll_64 = [530380, 543557, 603339, 558322, 551800, 562900, 577598, 551840]
plain_256 = [2247012, 2278469, 2268721, 2192198, 2252711, 2217082, 2211803, 2238233]
ring_256 = [2239767, 2255327, 2357648, 2310874, 2234285, 2208256, 2240377, 2236569]
sqpoll_256 = [1972668, 2313525, 2019773, 2096354, 2038088, 2571005, 2031907, 2288476]
for n, d in [("plain_64",plain_64),("ring_64",ring_64),("sqpoll_64",sqpoll_64),("plain_256",plain_256),("ring_256",ring_256),("sqpoll_256",sqpoll_256)]:
    print(f"{n}: mean={np.mean(d):.1f} std={np.std(d):.1f}")
