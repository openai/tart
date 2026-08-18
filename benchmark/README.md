# Benchmark

Tart comes with a Golang-based benchmarking utility that allows one to easily compare host and guest performance.

Currently, only Flexible I/O tester workloads are supported. To run them, first make sure that [passwordless sudo](https://serverfault.com/questions/160581/how-to-setup-passwordless-sudo-on-linux) is configured.

Then, [install Golang](https://go.dev/). The easiest way is through [Homebrew](https://brew.sh/):

```shell
brew install go
```

Finally, run the following command from this (`benchmark/`) directory:

```shell
go run cmd/main.go fio --image ghcr.io/cirruslabs/macos-tahoe-base:latest --prepare 'sudo purge && sync'
```

You can also enable the debugging output to diagnose issues:

```shell
go run cmd/main.go fio --debug
```

To compare an empty Tart home with the same pull after its immutable base has
been prewarmed, provide a standalone remote base image and a stacked image built
from it. For example, create and push a stacked child of the public Tahoe base:

```shell
BASE_IMAGE=ghcr.io/cirruslabs/macos-tahoe-base:latest
STACKED_IMAGE=ghcr.io/your-org/macos-tahoe-stacked:latest

tart clone --stacked "$BASE_IMAGE" macos-tahoe-stacked
tart push macos-tahoe-stacked "$STACKED_IMAGE"
```

Then benchmark that pair:

```shell
go run cmd/main.go stacked-oci \
  --base-image "$BASE_IMAGE" \
  --image "$STACKED_IMAGE"
```

The command first performs an unmeasured pull to warm registry, CDN, and
filesystem caches. It then uses disposable `TART_HOME` directories for both
measured scenarios. The prewarmed scenario keeps the VM created by
`tart clone --stacked` alive while pulling the child, so the shared immutable
base layer remains referenced and available for reuse.

## Results

### Mar 27, 2024

Host:

* Hardware: Mac mini (Apple M2 Pro, 8 performance and 4 efficiency cores, 32 GB RAM, `Mac14,12`)
* OS: macOS Sonoma 14.4.1

Guest:

* Hardware: [Virtualization.Framework](https://developer.apple.com/documentation/virtualization)
* OS: macOS Sonoma 14.4.1

```
Name                    	Executor	Bandwidth	I/O operations
Random writing of 1MB   	local   	2.6 GB/s 	649.35 kIOPS  
Random writing of 1MB   	Tart    	2.5 GB/s 	620.22 kIOPS  
Random writing of 10MB  	local   	2.6 GB/s 	651.74 kIOPS  
Random writing of 10MB  	Tart    	2.5 GB/s 	615.52 kIOPS  
Random writing of 100MB 	local   	1.9 GB/s 	481.51 kIOPS  
Random writing of 100MB 	Tart    	2.0 GB/s 	493.31 kIOPS  
Random writing of 1000MB	local   	1.7 GB/s 	414.89 kIOPS  
Random writing of 1000MB	Tart    	1.1 GB/s 	287.4 kIOPS  
```

### Dec 2, 2024

Host:

* Hardware: MacBook Pro (Apple M1 Pro, 8 performance and 2 efficiency cores, 32 GB RAM, `MacBookPro18,3`)
* OS: macOS Sequoia 15.1.1

Guest:

* Hardware: [Virtualization.Framework](https://developer.apple.com/documentation/virtualization)
* OS: macOS Sonoma 14.6

```
Name                                    	Executor                                          	B/W (read)	B/W (write)	I/O (read) 	I/O (write) 	Latency (read)          	Latency (write)         	Latency (sync)      
Single 4KiB random write process        	local                                             	0 B/s     	19 MB/s    	0 IOPS     	4.81 kIOPS  	0s ± 0s                 	203.418µs ± 155.865µs   	0s ± 0s             
Single 4KiB random write process        	Tart                                              	0 B/s     	18 MB/s    	0 IOPS     	4.54 kIOPS  	0s ± 0s                 	213.655µs ± 188.822µs   	0s ± 0s             
Single 4KiB random write process        	Tart (--root-disk-opts="sync=none")               	0 B/s     	19 MB/s    	0 IOPS     	4.68 kIOPS  	0s ± 0s                 	208.413µs ± 183.45µs    	0s ± 0s             
Single 4KiB random write process        	Tart (--root-disk-opts="caching=cached")          	0 B/s     	24 MB/s    	0 IOPS     	6.11 kIOPS  	0s ± 0s                 	158.07µs ± 2.294654ms   	0s ± 0s             
Single 4KiB random write process        	Tart (--root-disk-opts="sync=none,caching=cached")	0 B/s     	22 MB/s    	0 IOPS     	5.49 kIOPS  	0s ± 0s                 	173.414µs ± 310.213µs   	0s ± 0s             
16 parallel 64KiB random write processes	local                                             	0 B/s     	18 GB/s    	0 IOPS     	273.76 kIOPS	0s ± 0s                 	323.423µs ± 604.999µs   	0s ± 0s             
16 parallel 64KiB random write processes	Tart                                              	0 B/s     	16 GB/s    	0 IOPS     	273.48 kIOPS	0s ± 0s                 	335.086µs ± 7.591748ms  	0s ± 0s             
16 parallel 64KiB random write processes	Tart (--root-disk-opts="sync=none")               	0 B/s     	18 GB/s    	0 IOPS     	281.49 kIOPS	0s ± 0s                 	326.655µs ± 7.485473ms  	0s ± 0s             
16 parallel 64KiB random write processes	Tart (--root-disk-opts="caching=cached")          	0 B/s     	17 GB/s    	0 IOPS     	266.79 kIOPS	0s ± 0s                 	340µs ± 7.868384ms      	0s ± 0s             
16 parallel 64KiB random write processes	Tart (--root-disk-opts="sync=none,caching=cached")	0 B/s     	16 GB/s    	0 IOPS     	251.02 kIOPS	0s ± 0s                 	355.077µs ± 8.354218ms  	0s ± 0s             
Single 1MiB random write process        	local                                             	0 B/s     	1.3 GB/s   	0 IOPS     	1.31 kIOPS  	0s ± 0s                 	751.716µs ± 370.731µs   	0s ± 0s             
Single 1MiB random write process        	Tart                                              	0 B/s     	1.1 GB/s   	0 IOPS     	1.1 kIOPS   	0s ± 0s                 	885.833µs ± 3.572539ms  	0s ± 0s             
Single 1MiB random write process        	Tart (--root-disk-opts="sync=none")               	0 B/s     	1.1 GB/s   	0 IOPS     	1.08 kIOPS  	0s ± 0s                 	898.427µs ± 3.464261ms  	0s ± 0s             
Single 1MiB random write process        	Tart (--root-disk-opts="caching=cached")          	0 B/s     	1000 MB/s  	0 IOPS     	976.47 IOPS 	0s ± 0s                 	972.491µs ± 6.87654ms   	0s ± 0s             
Single 1MiB random write process        	Tart (--root-disk-opts="sync=none,caching=cached")	0 B/s     	1.1 GB/s   	0 IOPS     	1.03 kIOPS  	0s ± 0s                 	925.545µs ± 4.261693ms  	0s ± 0s             
Random reads/writes (4k)                	local                                             	62 MB/s   	62 MB/s    	15.37 kIOPS	15.37 kIOPS 	2.059453ms ± 1.431822ms 	2.098761ms ± 1.445082ms 	0s ± 0s             
Random reads/writes (4k)                	Tart                                              	38 MB/s   	38 MB/s    	9.6 kIOPS  	9.61 kIOPS  	3.30369ms ± 1.500464ms  	3.350589ms ± 1.512986ms 	0s ± 0s             
Random reads/writes (4k)                	Tart (--root-disk-opts="sync=none")               	39 MB/s   	39 MB/s    	9.82 kIOPS 	9.83 kIOPS  	3.228106ms ± 1.367512ms 	3.27626ms ± 1.385964ms  	0s ± 0s             
Random reads/writes (4k)                	Tart (--root-disk-opts="caching=cached")          	35 MB/s   	35 MB/s    	8.74 kIOPS 	8.76 kIOPS  	3.640772ms ± 15.472355ms	3.661779ms ± 15.264288ms	0s ± 0s             
Random reads/writes (4k)                	Tart (--root-disk-opts="sync=none,caching=cached")	24 MB/s   	24 MB/s    	5.98 kIOPS 	5.99 kIOPS  	5.31188ms ± 4.55205ms   	5.375047ms ± 5.113847ms 	0s ± 0s             
Random reads/writes (64k)               	local                                             	435 MB/s  	436 MB/s   	6.79 kIOPS 	6.8 kIOPS   	4.955892ms ± 2.066685ms 	4.440414ms ± 1.860036ms 	0s ± 0s             
Random reads/writes (64k)               	Tart                                              	352 MB/s  	353 MB/s   	5.5 kIOPS  	5.51 kIOPS  	5.946067ms ± 2.041124ms 	5.658948ms ± 1.928372ms 	0s ± 0s             
Random reads/writes (64k)               	Tart (--root-disk-opts="sync=none")               	331 MB/s  	332 MB/s   	5.16 kIOPS 	5.17 kIOPS  	6.330765ms ± 1.726782ms 	6.033862ms ± 1.671028ms 	0s ± 0s             
Random reads/writes (64k)               	Tart (--root-disk-opts="caching=cached")          	428 MB/s  	428 MB/s   	6.68 kIOPS 	6.69 kIOPS  	4.661666ms ± 18.342779ms	4.904961ms ± 18.396772ms	0s ± 0s             
Random reads/writes (64k)               	Tart (--root-disk-opts="sync=none,caching=cached")	297 MB/s  	298 MB/s   	4.64 kIOPS 	4.65 kIOPS  	6.591009ms ± 2.827053ms 	7.166883ms ± 3.001036ms 	0s ± 0s             
sync test                               	local                                             	0 B/s     	48 MB/s    	0 IOPS     	21.15 kIOPS 	0s ± 0s                 	23.471µs ± 81.868µs     	23.374µs ± 6.255µs  
sync test                               	Tart                                              	0 B/s     	24 MB/s    	0 IOPS     	10.72 kIOPS 	0s ± 0s                 	24.983µs ± 61.761µs     	67.575µs ± 76.196µs 
sync test                               	Tart (--root-disk-opts="sync=none")               	0 B/s     	21 MB/s    	0 IOPS     	9.5 kIOPS   	0s ± 0s                 	26.973µs ± 63.935µs     	77.388µs ± 47.103µs 
sync test                               	Tart (--root-disk-opts="caching=cached")          	0 B/s     	30 MB/s    	0 IOPS     	13.19 kIOPS 	0s ± 0s                 	11.923µs ± 25.225µs     	62.894µs ± 208.933µs
sync test                               	Tart (--root-disk-opts="sync=none,caching=cached")	0 B/s     	38 MB/s    	0 IOPS     	17.02 kIOPS 	0s ± 0s                 	10.124µs ± 21.868µs     	47.803µs ± 33.706µs
```

### Dec 4, 2024

Host:

* AWS instance: `mac2.metal` + `gp3` EBS volume
* Hardware: Mac mini (Apple M1, 4 performance and 4 efficiency cores, 16 GB RAM, `Macmini9,1`)
* OS: macOS Sequoia 15.0

Guest:

* Hardware: [Virtualization.Framework](https://developer.apple.com/documentation/virtualization)
* OS: macOS Sonoma 14.6

```
Name                                    	Executor                                          	B/W (read)	B/W (write)	I/O (read) 	I/O (write) 	Latency (read)            	Latency (write)           	Latency (sync)         
Single 4KiB random write process        	local                                             	0 B/s     	4.4 MB/s   	0 IOPS     	1.1 kIOPS   	0s ± 0s                   	702.357µs ± 359.925µs     	0s ± 0s                
Single 4KiB random write process        	Tart                                              	0 B/s     	2.6 MB/s   	0 IOPS     	656.37 IOPS 	0s ± 0s                   	1.140086ms ± 1.450472ms   	0s ± 0s                
Single 4KiB random write process        	Tart (--root-disk-opts="sync=none")               	0 B/s     	2.7 MB/s   	0 IOPS     	677.07 IOPS 	0s ± 0s                   	1.179872ms ± 1.219626ms   	0s ± 0s                
Single 4KiB random write process        	Tart (--root-disk-opts="caching=cached")          	0 B/s     	3.3 MB/s   	0 IOPS     	832.66 IOPS 	0s ± 0s                   	948.648µs ± 94.141338ms   	0s ± 0s                
Single 4KiB random write process        	Tart (--root-disk-opts="sync=none,caching=cached")	0 B/s     	15 MB/s    	0 IOPS     	3.65 kIOPS  	0s ± 0s                   	260.717µs ± 19.977757ms   	0s ± 0s                
16 parallel 64KiB random write processes	local                                             	0 B/s     	9.5 GB/s   	0 IOPS     	147.89 kIOPS	0s ± 0s                   	753.289µs ± 8.028974ms    	0s ± 0s                
16 parallel 64KiB random write processes	Tart                                              	0 B/s     	10 GB/s    	0 IOPS     	176.96 kIOPS	0s ± 0s                   	429.83µs ± 33.792264ms    	0s ± 0s                
16 parallel 64KiB random write processes	Tart (--root-disk-opts="sync=none")               	0 B/s     	12 GB/s    	0 IOPS     	180.89 kIOPS	0s ± 0s                   	383.524µs ± 17.524971ms   	0s ± 0s                
16 parallel 64KiB random write processes	Tart (--root-disk-opts="caching=cached")          	0 B/s     	336 MB/s   	0 IOPS     	5.24 kIOPS  	0s ± 0s                   	9.970844ms ± 365.808663ms 	0s ± 0s                
16 parallel 64KiB random write processes	Tart (--root-disk-opts="sync=none,caching=cached")	0 B/s     	9.4 GB/s   	0 IOPS     	147.04 kIOPS	0s ± 0s                   	524.139µs ± 34.100009ms   	0s ± 0s                
Single 1MiB random write process        	local                                             	0 B/s     	178 MB/s   	0 IOPS     	173.36 IOPS 	0s ± 0s                   	3.835103ms ± 2.917977ms   	0s ± 0s                
Single 1MiB random write process        	Tart                                              	0 B/s     	140 MB/s   	0 IOPS     	136.48 IOPS 	0s ± 0s                   	4.721178ms ± 7.744965ms   	0s ± 0s                
Single 1MiB random write process        	Tart (--root-disk-opts="sync=none")               	0 B/s     	144 MB/s   	0 IOPS     	140.63 IOPS 	0s ± 0s                   	4.443507ms ± 11.572454ms  	0s ± 0s                
Single 1MiB random write process        	Tart (--root-disk-opts="caching=cached")          	0 B/s     	47 MB/s    	0 IOPS     	45.55 IOPS  	0s ± 0s                   	13.267881ms ± 358.283094ms	0s ± 0s                
Single 1MiB random write process        	Tart (--root-disk-opts="sync=none,caching=cached")	0 B/s     	196 MB/s   	0 IOPS     	191.4 IOPS  	0s ± 0s                   	4.102516ms ± 73.117503ms  	0s ± 0s                
Random reads/writes (4k)                	local                                             	8.7 MB/s  	8.7 MB/s   	2.16 kIOPS 	2.16 kIOPS  	193.370794ms ± 42.593607ms	222.272016ms ± 56.586971ms	0s ± 0s                
Random reads/writes (4k)                	Tart                                              	4.1 MB/s  	4.1 MB/s   	1.02 kIOPS 	1.03 kIOPS  	31.038867ms ± 13.508668ms 	31.184305ms ± 14.032766ms 	0s ± 0s                
Random reads/writes (4k)                	Tart (--root-disk-opts="sync=none")               	4.2 MB/s  	4.2 MB/s   	1.04 kIOPS 	1.05 kIOPS  	30.368422ms ± 13.505627ms 	30.595412ms ± 13.840944ms 	0s ± 0s                
Random reads/writes (4k)                	Tart (--root-disk-opts="caching=cached")          	2.2 MB/s  	2.2 MB/s   	545.33 IOPS	548.86 IOPS 	59.31316ms ± 716.351086ms 	57.647852ms ± 711.503882ms	0s ± 0s                
Random reads/writes (4k)                	Tart (--root-disk-opts="sync=none,caching=cached")	6.0 MB/s  	6.0 MB/s   	1.5 kIOPS  	1.5 kIOPS   	21.244222ms ± 47.808399ms 	21.39459ms ± 44.716307ms  	0s ± 0s                
Random reads/writes (64k)               	local                                             	121 MB/s  	121 MB/s   	1.89 kIOPS 	1.89 kIOPS  	61.894699ms ± 21.353345ms 	73.176462ms ± 13.02948ms  	0s ± 0s                
Random reads/writes (64k)               	Tart                                              	72 MB/s   	72 MB/s    	1.12 kIOPS 	1.12 kIOPS  	27.842263ms ± 15.320781ms 	29.161858ms ± 15.765314ms 	0s ± 0s                
Random reads/writes (64k)               	Tart (--root-disk-opts="sync=none")               	71 MB/s   	72 MB/s    	1.11 kIOPS 	1.11 kIOPS  	28.009493ms ± 16.333136ms 	29.285868ms ± 16.540589ms 	0s ± 0s                
Random reads/writes (64k)               	Tart (--root-disk-opts="caching=cached")          	28 MB/s   	28 MB/s    	441.85 IOPS	444.81 IOPS 	71.726725ms ± 633.215756ms	72.597238ms ± 630.969305ms	0s ± 0s                
Random reads/writes (64k)               	Tart (--root-disk-opts="sync=none,caching=cached")	81 MB/s   	81 MB/s    	1.26 kIOPS 	1.26 kIOPS  	24.872043ms ± 36.980111ms 	25.568559ms ± 37.027145ms 	0s ± 0s                
sync test                               	local                                             	0 B/s     	1.9 MB/s   	0 IOPS     	868.08 IOPS 	0s ± 0s                   	92.08µs ± 233.598µs       	1.059033ms ± 98.751µs  
sync test                               	Tart                                              	0 B/s     	1.5 MB/s   	0 IOPS     	649.42 IOPS 	0s ± 0s                   	146.737µs ± 434.261µs     	1.391898ms ± 699.148µs 
sync test                               	Tart (--root-disk-opts="sync=none")               	0 B/s     	1.3 MB/s   	0 IOPS     	568.82 IOPS 	0s ± 0s                   	158.736µs ± 504.002µs     	1.59798ms ± 14.161331ms
sync test                               	Tart (--root-disk-opts="caching=cached")          	0 B/s     	13 MB/s    	0 IOPS     	5.77 kIOPS  	0s ± 0s                   	26.596µs ± 832.169µs      	145.785µs ± 2.864048ms 
sync test                               	Tart (--root-disk-opts="sync=none,caching=cached")	0 B/s     	19 MB/s    	0 IOPS     	8.37 kIOPS  	0s ± 0s                   	20.135µs ± 108.817µs      	98.274µs ± 239.631µs   
```

Host:

* AWS instance: `mac2.metal` + `gp3` EBS volume
* Hardware: Mac mini (Apple M1, 4 performance and 4 efficiency cores, 16 GB RAM, `Macmini9,1`)
* OS: macOS Sequoia 15.0

Guest:

* Hardware: [Virtualization.Framework](https://developer.apple.com/documentation/virtualization)
* OS: macOS Sequoia 15.1

```
Name                                    	Executor                                          	B/W (read)	B/W (write)	I/O (read) 	I/O (write) 	Latency (read)            	Latency (write)           	Latency (sync)         
Single 4KiB random write process        	local                                             	0 B/s     	4.8 MB/s   	0 IOPS     	1.19 kIOPS  	0s ± 0s                   	690.818µs ± 326.595µs     	0s ± 0s                
Single 4KiB random write process        	Tart                                              	0 B/s     	2.8 MB/s   	0 IOPS     	700.94 IOPS 	0s ± 0s                   	1.090362ms ± 918.444µs    	0s ± 0s                
Single 4KiB random write process        	Tart (--root-disk-opts="sync=none")               	0 B/s     	3.0 MB/s   	0 IOPS     	746.23 IOPS 	0s ± 0s                   	1.028192ms ± 974.533µs    	0s ± 0s                
Single 4KiB random write process        	Tart (--root-disk-opts="caching=cached")          	0 B/s     	4.2 MB/s   	0 IOPS     	1.04 kIOPS  	0s ± 0s                   	916.36µs ± 105.318323ms   	0s ± 0s                
Single 4KiB random write process        	Tart (--root-disk-opts="sync=none,caching=cached")	0 B/s     	14 MB/s    	0 IOPS     	3.57 kIOPS  	0s ± 0s                   	269.796µs ± 22.419599ms   	0s ± 0s                
16 parallel 64KiB random write processes	local                                             	0 B/s     	9.5 GB/s   	0 IOPS     	148.74 kIOPS	0s ± 0s                   	753.46µs ± 8.06509ms      	0s ± 0s                
16 parallel 64KiB random write processes	Tart                                              	0 B/s     	5.2 GB/s   	0 IOPS     	81.46 kIOPS 	0s ± 0s                   	778.624µs ± 11.705178ms   	0s ± 0s                
16 parallel 64KiB random write processes	Tart (--root-disk-opts="sync=none")               	0 B/s     	5.3 GB/s   	0 IOPS     	83.47 kIOPS 	0s ± 0s                   	865.448µs ± 38.369176ms   	0s ± 0s                
16 parallel 64KiB random write processes	Tart (--root-disk-opts="caching=cached")          	0 B/s     	116 MB/s   	0 IOPS     	1.8 kIOPS   	0s ± 0s                   	37.601112ms ± 727.319309ms	0s ± 0s                
16 parallel 64KiB random write processes	Tart (--root-disk-opts="sync=none,caching=cached")	0 B/s     	5.3 GB/s   	0 IOPS     	83.19 kIOPS 	0s ± 0s                   	900.751µs ± 51.223205ms   	0s ± 0s                
Single 1MiB random write process        	local                                             	0 B/s     	177 MB/s   	0 IOPS     	173.27 IOPS 	0s ± 0s                   	3.833194ms ± 2.873871ms   	0s ± 0s                
Single 1MiB random write process        	Tart                                              	0 B/s     	151 MB/s   	0 IOPS     	147.44 IOPS 	0s ± 0s                   	4.925853ms ± 7.793808ms   	0s ± 0s                
Single 1MiB random write process        	Tart (--root-disk-opts="sync=none")               	0 B/s     	151 MB/s   	0 IOPS     	147.87 IOPS 	0s ± 0s                   	4.884797ms ± 7.563512ms   	0s ± 0s                
Single 1MiB random write process        	Tart (--root-disk-opts="caching=cached")          	0 B/s     	72 MB/s    	0 IOPS     	69.9 IOPS   	0s ± 0s                   	8.909771ms ± 214.311644ms 	0s ± 0s                
Single 1MiB random write process        	Tart (--root-disk-opts="sync=none,caching=cached")	0 B/s     	159 MB/s   	0 IOPS     	155.69 IOPS 	0s ± 0s                   	4.863448ms ± 88.965211ms  	0s ± 0s                
Random reads/writes (4k)                	local                                             	8.7 MB/s  	8.7 MB/s   	2.16 kIOPS 	2.16 kIOPS  	193.353233ms ± 42.728494ms	222.325905ms ± 56.901372ms	0s ± 0s                
Random reads/writes (4k)                	Tart                                              	3.5 MB/s  	3.5 MB/s   	862.89 IOPS	865.54 IOPS 	36.893229ms ± 12.644216ms 	37.143334ms ± 12.772017ms 	0s ± 0s                
Random reads/writes (4k)                	Tart (--root-disk-opts="sync=none")               	3.6 MB/s  	3.6 MB/s   	907.4 IOPS 	911.55 IOPS 	35.048969ms ± 10.559354ms 	35.3046ms ± 10.67824ms    	0s ± 0s                
Random reads/writes (4k)                	Tart (--root-disk-opts="caching=cached")          	2.7 MB/s  	2.8 MB/s   	684.11 IOPS	688.05 IOPS 	48.815322ms ± 687.806727ms	44.395556ms ± 635.532064ms	0s ± 0s                
Random reads/writes (4k)                	Tart (--root-disk-opts="sync=none,caching=cached")	7.0 MB/s  	7.0 MB/s   	1.74 kIOPS 	1.74 kIOPS  	18.00448ms ± 93.784447ms  	18.617037ms ± 107.423001ms	0s ± 0s                
Random reads/writes (64k)               	local                                             	121 MB/s  	121 MB/s   	1.89 kIOPS 	1.89 kIOPS  	61.983727ms ± 21.324782ms 	73.228597ms ± 12.730945ms 	0s ± 0s                
Random reads/writes (64k)               	Tart                                              	75 MB/s   	75 MB/s    	1.17 kIOPS 	1.17 kIOPS  	26.830538ms ± 7.643051ms  	27.709602ms ± 7.830965ms  	0s ± 0s                
Random reads/writes (64k)               	Tart (--root-disk-opts="sync=none")               	76 MB/s   	77 MB/s    	1.19 kIOPS 	1.19 kIOPS  	26.255337ms ± 7.302592ms  	27.256805ms ± 7.388266ms  	0s ± 0s                
Random reads/writes (64k)               	Tart (--root-disk-opts="caching=cached")          	32 MB/s   	33 MB/s    	505.26 IOPS	508.66 IOPS 	65.170269ms ± 747.794957ms	61.062186ms ± 695.614904ms	0s ± 0s                
Random reads/writes (64k)               	Tart (--root-disk-opts="sync=none,caching=cached")	79 MB/s   	79 MB/s    	1.23 kIOPS 	1.23 kIOPS  	25.861503ms ± 171.669777ms	25.992302ms ± 164.647788ms	0s ± 0s                
sync test                               	local                                             	0 B/s     	1.9 MB/s   	0 IOPS     	865.16 IOPS 	0s ± 0s                   	100.95µs ± 268.722µs      	1.054051ms ± 365.377µs 
sync test                               	Tart                                              	0 B/s     	1.6 MB/s   	0 IOPS     	704.13 IOPS 	0s ± 0s                   	133.886µs ± 390.263µs     	1.285085ms ± 575.27µs  
sync test                               	Tart (--root-disk-opts="sync=none")               	0 B/s     	1.6 MB/s   	0 IOPS     	728.26 IOPS 	0s ± 0s                   	129.246µs ± 472.724µs     	1.242713ms ± 1.281286ms
sync test                               	Tart (--root-disk-opts="caching=cached")          	0 B/s     	35 MB/s    	0 IOPS     	15.67 kIOPS 	0s ± 0s                   	11.319µs ± 24.771µs       	51.731µs ± 42.208µs    
sync test                               	Tart (--root-disk-opts="sync=none,caching=cached")	0 B/s     	17 MB/s    	0 IOPS     	7.39 kIOPS  	0s ± 0s                   	21.23µs ± 81.749µs        	113.239µs ± 191.266µs  
```

### March 23, 2025

Host:

* Hardware: Mac mini (Apple M2 Pro, 8 performance and 4 efficiency cores, 32 GB RAM, `Mac14,12`)
* OS: macOS Sequoia 15.3.2
* Xcode: 16.2

Guest:

* Hardware: [Virtualization.Framework](https://developer.apple.com/documentation/virtualization)
* OS: macOS Sonoma 15.3.2 
* Xcode: 16.2

```
Name                    	Executor                                          	Time 
XcodeBenchmark (d869315)	local                                             	2m19s
XcodeBenchmark (d869315)	Tart                                              	3m59s
XcodeBenchmark (d869315)	Tart (--root-disk-opts="sync=none")               	3m48s
XcodeBenchmark (d869315)	Tart (--root-disk-opts="caching=cached")          	3m35s
XcodeBenchmark (d869315)	Tart (--root-disk-opts="sync=none,caching=cached")	3m14s
```
