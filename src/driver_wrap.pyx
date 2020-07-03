#
#  BSD LICENSE
#
#  Copyright (c) Crane Chu <cranechu@gmail.com>
#  All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#
#    * Redistributions of source code must retain the above copyright
#      notice, this list of conditions and the following disclaimer.
#    * Redistributions in binary form must reproduce the above copyright
#      notice, this list of conditions and the following disclaimer in
#      the documentation and/or other materials provided with the
#      distribution.
#    * Neither the name of Intel Corporation nor the names of its
#      contributors may be used to endorse or promote products derived
#      from this software without specific prior written permission.
#
#  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
#  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
#  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
#  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
#  OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
#  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
#  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
#  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
#  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


#!/usr/bin/python3
# -*- coding: utf-8 -*-
#cython: linetrace=True
#cython: language_level=3
#cython: embedsignature=True

# for generating api.md only
##cython: binding=True


# python package
import os
import sys
import time
import glob
import math
import atexit
import signal
import struct
import random
import logging
import warnings
import datetime
import statistics
import subprocess
import multiprocessing
#import nvme_spec

# c library
import cython
from inspect import signature
from libc.string cimport strncpy, memset, strlen
from libc.stdio cimport printf
from cpython.mem cimport PyMem_Malloc, PyMem_Free
from cpython.exc cimport PyErr_CheckSignals

# c driver
cimport cdriver as d


# module informatoin
__author__ = "Crane Chu"
__version__ = "1.9"


# nvme command timeout, it's a warning
# drive times out earlier than driver timeout
_cTIMEOUT = 10
_timeout_happened = False
cdef void timeout_driver_cb(void* cb_arg, d.ctrlr* ctrlr,
                            d.qpair * qpair, unsigned short cid):
    _timeout_happened = True
    error_string = "drive timeout: qpair: %d, cid: %d" % \
        (d.qpair_get_id(qpair), cid)
    warnings.warn(error_string)


def _timeout_signal_handler(signum, frame):
    error_string = "pynvme timeout in driver"
    _reentry_flag_init()
    raise TimeoutError(error_string)


# prevent waitdone reentry
def _reentry_flag_init():
    global _reentry_flag
    _reentry_flag = False


# for abrupt exit
def _interrupt_handler(signal, frame):
    logging.debug("terminated.")
    sys.exit(0)


# handle completion dwords in callback from c
cdef struct _cpl:
    unsigned int cdw0
    unsigned int rsvd1
    unsigned short sqhead
    unsigned short sqid
    unsigned short cid
    unsigned short status1  #this word actully inculdes some other bits


cdef void cmd_cb(void* f, const d.cpl* cpl):
    cdef unsigned int cdw2
    cdef unsigned int cdw3

    global _latest_cqe_cdw0
    arg = <_cpl*>cpl  # no qa
    status1 = arg.status1
    func = <object>f   # no qa
    _latest_cqe_cdw0 = arg.cdw0

    if func is not None:
        # call script callback function to check cpl
        try:
            # we support 2 types of callback (dword0, status1), and (cpl)
            argc = len(signature(func).parameters)
            assert argc == 1 or argc == 2, "command callback has illegal parameter list"
            if argc == 2:
                func(arg.cdw0, status1)
            else:
                cdw2 = arg.sqid
                cdw3 = arg.status1
                func((arg.cdw0,
                      arg.rsvd1,
                      (cdw2<<16)+arg.sqhead,
                      (cdw3<<16)+arg.cid))
        except AssertionError as e:
            warnings.warn("ASSERT: "+str(e))

    if d.nvme_cpl_is_error(cpl):
        # script not check, so driver check cpl
        sc = (status1>>1) & 0xff
        sct = (status1>>9) & 0x7
        warnings.warn("ERROR status: %02x/%02x" % (sct, sc))


cdef void aer_cmd_cb(void* f, const d.cpl* cpl):
    arg = <_cpl*>cpl  # no qa

    # filter aer completion at SQ deletion
    if (arg.status1>>1) == 8:
        return

    if (arg.status1>>1) != 7:
        # not raise warning when aborted
        logging.warning("AER triggered, dword0: 0x%x, status1: 0x%x" %
                        (arg.cdw0, arg.status1))
        warnings.warn("AER notification is triggered: 0x%x" % arg.cdw0)
    else:
        assert arg.cdw0 == 0

    # call the callback function of aer command
    cmd_cb(f, cpl)


cdef class Buffer(object):
    """Buffer allocates memory in DPDK, so we can get its physical address for DMA. Data in buffer is clear to 0 in initialization.

    # Parameters
        size (int): the size (in bytes) of the buffer. Default: 4096
        name (str): the name of the buffer. Default: 'buffer'
        pvalue (int): data pattern value. Default: 0
        ptype (int): data pattern type. Default: 0

    # data patterns
```md
        |ptype    | pvalue                                                     |
        |---------|------------------------------------------------------------|
        |0        | 0 for all-zero data, 1 for all-one data                    |
        |32       | 32-bit value of the repeated data pattern                  |
        |0xbeef   | random data compressed rate (0: all 0; 100: fully random)  |
        |others   | not supported                                              |
```

    # Examples
```python
        >>> b = Buffer(1024, 'example')
        >>> b[0] = 0x5a
        >>> b[1:3] = [1, 2]
        >>> b[4:] = [10, 11, 12, 13]
        >>> b.dump(16)
        example
        00000000  5a 01 02 00 0a 0b 0c 0d  00 00 00 00 00 00 00 00   Z...............
        >>> b[:8:2]
        b'Z\\x02\\n\\x0c'
        >>> b.data(2) == 2
        True
        >>> b[2] == 2
        True
        >>> b.data(2, 0) == 0x02015a
        True
        >>> len(b)
        1024
        >>> b
        <buffer name: example>
        >>> b[8:] = b'xyc'
        example
        00000000  5a 01 02 00 0a 0b 0c 0d  78 79 63 00 00 00 00 00   Z.......xyc.....
        >>> b.set_dsm_range(1, 0x1234567887654321, 0xabcdef12)
        >>> b.dump(64)
        buffer
        00000000  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  ................
        00000010  00 00 00 00 12 ef cd ab  21 43 65 87 78 56 34 12  ........!Ce.xV4.
        00000020  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  ................
        00000030  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00   ................
```
    """

    cdef void* ptr
    cdef size_t size
    cdef char* name
    cdef unsigned long phys_addr
    cdef unsigned int offset

    def __cinit__(self, size=4096, name="buffer", pvalue=0, ptype=0):
        assert size > 0, "0 is not valid size"

        # copy python string to c string
        name_len = (len(name)+1)*sizeof(char)
        self.name = <char*>PyMem_Malloc(name_len)
        if not self.name:
            raise MemoryError()
        memset(self.name, 0, name_len)
        strncpy(self.name, name.encode('ascii'), len(name))

        # buffer init
        self.size = size
        self.offset = 0
        self.ptr = d.buffer_init(size, &self.phys_addr, ptype, pvalue)
        if self.ptr is NULL:
            raise MemoryError()

    def __dealloc__(self):
        if self.name is not NULL:
            PyMem_Free(self.name)

        if self.ptr is not NULL:
            d.buffer_fini(self.ptr)

    @property
    def data_head(self):
        return self.dump().split('\n')[0][:-2].encode('ascii')

    @property
    def data_tail(self):
        return self.dump().split('\n')[-2][:-2].encode('ascii')

    @property
    def offset(self):
        """get the offset of the PRP in bytes"""
        return self.offset

    @offset.setter
    def offset(self, offset):
        """set the offset of the PRP in bytes"""
        self.offset = offset

    @property
    def phys_addr(self):
        """physical address of the buffer"""
        return self.phys_addr + self.offset

    def dump(self, size=None):
        """get the buffer content

        # Parameters
            size (int): the size of the buffer to print. Default: None, means to print the whole buffer
        """
        output = ''
        base = 0
        if self.ptr and self.size:
            # no size means print the whole buffer
            if size is None or size > self.size:
                size = self.size

            while size:
                length = min(size, 4096)
                dbuf = d.log_buf_dump(self.name, self.ptr, length, base)
                output += dbuf.decode('ascii')[:]
                base += length
                size -= length
        return output

    def data(self, byte_end, byte_begin=None, type=int):
        """get field in the buffer. Little endian for integers.

        # Parameters
            byte_end (int): the end byte number of this field, which is specified in NVMe spec. Included.
            byte_begin (int): the begin byte number of this field, which is specified in NVMe spec. It can be omitted if begin is the same as end when the field has only 1 byte. Included. Default: None, means only get 1 byte defined in byte_end
            type (type): the type of the field. It should be int or str. Default: int, convert to integer python object

        Returns
            (int or str): the data in the specified field
        """
# TODO: Add support for different NVMe spec versions

        id_ns = {"NSZE":(7,0,"int"), "NCAP":(15,8,"int"), "NUSE":(23,16,"int"),"NSFEAT":(24,24,"int"),"NLBAF":(25,25,"int"), \
                "FLBAS":(26,26,"int"),"MC":(27,27,"int"), "DPC":(28,28,"int"),"DPS":(29,29,"int"), "NMIC":(30,30,"int"), \
                "RESCAP":(31,31,"int"),"FPI":(32,32,"int"), "DLFEAT":(33,33,"int"),"NAWUN":(35,34,"int"), \
                "NAWUPF":(37,36,"int"),"NACWU":(39,38,"int"),"NABSN":(41,40,"int"), "NABO":(43,42,"int"), \
                "NABSPF":(45,44,"int"),"NOIOB":(47,46,"int"), "NVMCAP":(63,48,"int"),"NPWG":(65,64,"int"), \
                "NPWA":(67,66,"int"), "NPDG":(69,68,"int"), "NPDA":(71,70,"int"),"NOWS":(73,72,"int"), \
                "ANAGRPID":(95,92,"int"), "NSATTR":(99,99,"int"), "NVMSETID":(101,100,"int"), "ENDGID":(103,102,"int"), \
                "NGUID":(119,104,"str"), "EUI64":(127,120,"str"), "LBAF0":(127,120,"int") }

        id_ctrl = {"VID":(1,0,"int"), "SSVID":(3,2,"int"), "SN":(23,4,"str"),"MN":(63,24,"str"),"FR":(71,64,"str"), \
                "RAB":(72,72,"int"), "IEEE":(75,73,"str"), "CMIC":(76,76,"int"), "MDTS":(77,77,"int"), \
                "CNTLID":(79,78,"int"),"VER":(83,80,"str"), "RTD3R":(87,84,"int"), "RTD3E":(91,88,"int"), \
                "OAES":(95,92,"int"), "CTRATT":(99,96,"int"), "RRLS":(101,100,"int"), "CNTRLTYPE":(111,111,"int"), \
                "FGUID":(127,112,"str"), "CRDT1":(129,128,"int"), "CRDT2":(131,130,"int"), "CRDT3":(133,132,"int"), \
                "OACS":(257,256,"int"), "ACL":(258,258,"int"), "AERL":(259,259,"int"), "FRMW":(260,260,"int"), \
                "LPA":(261,261,"int"), "ELPE":(262,262,"int"), "NPSS":(263,263,"int"), "AVSCC":(264,264,"int"), \
                "APSTA":(265,265,"int"), "WCTEMP":(267,266,"int"), "CCTEMP":(269,268,"int"), "MTFA":(271,270,"int"), \
                "HMPRE":(275,272,"int"), "HMMIN":(279,276,"int"), "TNVMCAP":(295,280,"int"), "UNVMCAP":(311,296,"int"),  \
                "RPMBS":(315,312,"int"), "EDSTT":(317,316,"int"), "DSTO":(318,318,"int"), "FWUG":(319,319,"int"), \
                "KAS":(321,320,"int"), "HCTMA":(323,322,"int"), "MNTMT":(325,324,"int"),"MXTMT":(327,326,"int"), \
                "SANICAP":(331,328,"int"), "HMMINDS":(335,332,"int"), "HMMAXD":(337,336,"int"), "NSETIDMAX":(339,338,"int"), \
                "ENDGIDMAX":(341,340,"int"), "ANATT":(342,342,"int"), "ANACAP":(343,343,"int"), "ANAGRPMAX":(347,344,"int"), \
                "NANAGRPID":(351,348,"int"), "PELS":(355,352,"int"),"SQES":(512,512,"int"),"CQES":(513,513,"int"), \
                "MAXCMD":(515,514,"int"), "NN":(519,516,"int"), "ONCS":(521,520,"int"), "FUSES":(523,522,"int"), \
                "FNA":(524,524,"int"), "VWC":(525,525,"int"), "AWUN":(527,526,"int"),"AWUPF":(529,528,"int"), \
                "NVSCC":(530,530,"int"), "NWPC":(531,531,"int"), "ACWU":(533,532,"int"), "SGLS":(539,536,"int"), \
                "MNAN":(543,540,"int"), "SUBNQN":(1023,768,"str"), "PSD0_APS":(2007,2006,"int"), "PSD0_APW":(2002,2000,"int"), \
                "PSD0_ACTP":(1999,1994,"int"), "PSD0_IPS":(1985,1984,"int") }

        if byte_begin is None:
            byte_begin = byte_end

        if type is int:
            return int.from_bytes(self[byte_begin:byte_end+1], 'little')
        elif type is str:
            #assert type is str, "identify data should be int or str"
            return str(self[byte_begin:byte_end+1], "ascii").rstrip()
        elif type in id_ctrl:
            if id_ctrl[type][2] == "int":
                return int.from_bytes(self[ id_ctrl[type][1]:id_ctrl[type][0]+1], 'little')
            else:
                return str(self[ id_ctrl[type][1]:id_ctrl[type][0]+1], "ascii").rstrip() 
        elif type in id_ns:
            if id_ns[type][2] == "int":
                return int.from_bytes(self[ id_ns[type][1]:id_ns[type][0]+1], 'little')
            else:
                return str(self[ id_ns[type][1]:id_ns[type][0]+1], "ascii").rstrip()                
        else:
            assert "identify data type should be int,str or legal keyword!"
            return 0

    def __len__(self):
        return self.size

    def __repr__(self):
        return '<buffer name: %s>' % str(self.name, "ascii")

    def __getitem__(self, index):
        if isinstance(index, slice):
            return bytes([self[i] for i in range(*index.indices(len(self)))])
        elif isinstance(index, int):
            if index >= self.size:
                raise IndexError()
            return (<unsigned char*>self.ptr)[index]
        else:
            raise TypeError()

    def __setitem__(self, index, value):
        if isinstance(index, slice):
            start = 0 if index.start is None else index.start
            for i, d in enumerate(value):
                self[i+start] = d
        elif isinstance(index, int):
            if index >= self.size:
                raise IndexError()
            (<unsigned char*>self.ptr)[index] = value
        else:
            raise TypeError()

    def set_dsm_range(self, index, lba, lba_count, attr=0):
        """set dsm ranges in the buffer, for dsm/deallocation (a.ka trim) commands

        # Parameters
            index (int): the index of the dsm range to set
            lba (int): the start lba of the range
            lba_count (int): the lba count of the range
            attr (int): context attributes of the range
        """

        assert type(lba) is int, "parameter must be integer"
        assert type(lba_count) is int, "parameter must be integer"

        self[index*16:(index+1)*16] = struct.pack("<LLQ", attr, lba_count, lba)


class NvmeShutdownStatusTimeoutError(Exception):
    pass

cdef class Subsystem(object):
    """Subsystem class. Prefer to use fixture "subsystem" in test scripts.

    # Parameters
        nvme (Controller): the nvme controller object of that subsystem
        poweron_cb (func): callback of poweron function
        poweroff_cb (func): callback of poweroff function
    """

    cdef Controller _nvme
    cdef char _vdid[64]
    cdef object _poweron
    cdef object _poweroff

    def __cinit__(self, Controller nvme, poweron_cb=None, poweroff_cb=None):
        self._nvme = nvme
        self._poweron = poweron_cb
        self._poweroff = poweroff_cb
        vdid = '%04x %04x' % (self._nvme.pcie.register(0, 2),
                              self._nvme.pcie.register(2, 2))
        vdid = vdid.encode('utf-8')
        strncpy(self._vdid, vdid, strlen(vdid)+1)

    def poweroff(self):
        """power off the device by the poweroff function provided in Subsystem initialization
        """

        # cut power supply immediately without any delay
        if self._poweroff:
            logging.info("power off callback")
            self._poweroff()

        pcie = self._nvme.pcie
        bdf = pcie._bdf.decode('utf-8')

        # cleanup host driver after power off, so IO is active at power off
        pcie._driver_cleanup()
        pcie._bind_driver(None)
        subprocess.call('echo 1 > "/sys/bus/pci/devices/%s/remove" 2> /dev/null || true' % bdf, shell=True)

        if not self._poweroff:
            self.power_cycle(15)

        return True

    def poweron(self):
        """power on the device by the poweron function provided in Subsystem initialization

        Notice
            call Controller.reset() to re-initialize controller after this power on
        """

        if self._poweron:
            logging.info("power on callback")
            self._poweron()

        pcie = self._nvme.pcie

        # config spdk driver
        pcie._rescan()
        pcie._bind_driver('uio_pci_generic')
        logging.info("reset controller to use it after power on")
        return True

    def power_cycle(self, sec=10):
        """power off and on in seconds

        Notice
            call Controller.reset() to re-initialize controller after this power cycle

        # Parameters
            sec (int): the seconds between power off and power on
        """

        if not b'deep' in subprocess.check_output(["sudo", "cat", "/sys/power/mem_sleep"]):
            logging.warning("S3 is not supported on this platform")
            return

        # use S3/suspend to power off nvme device, and use rtc to power on again
        self._nvme.pcie._driver_cleanup()
        logging.info("power off nvme device for %d seconds by S3" % sec)
        subprocess.call("sudo rtcwake -m mem -s %d 1>/dev/null 2>/dev/null" % sec, shell=True)
        logging.info("power is back by RTC")
        logging.info("reset controller to use it after power cycle")
        return True

    def shutdown_notify(self, abrupt=False):
        """notify nvme subsystem a shutdown event through register cc.shn

        # Parameters
            abrupt (bool): it will be an abrupt shutdown (return immediately) or clean shutdown (wait shutdown completely)
        """

        # refer to spec 7.6.2, host delay is recommended
        rtd3e = self._nvme.id_data(91, 88)
        if rtd3e == 0:
            rtd3e = 1000_000

        # cc.shn
        cc = self._nvme[0x14]
        if abrupt:
            cc = cc | 0x8000
        else:
            cc = cc | 0x4000
        self._nvme[0x14] = cc

        # csts.shst: wait shutdown processing is complete
        time.sleep(rtd3e/1000_000)
        t = time.time()
        while (self._nvme[0x1c] & 0xc) != 0x8:
            if time.time()-t > _cTIMEOUT:
                logging.error("csts.shst timeout after setting cc.shn")
                raise NvmeShutdownStatusTimeoutError("csts.shst timeout")

        logging.debug("shutdown completed")

    def reset(self):  # subsystem
        """reset the nvme subsystem through register nssr.nssrc

        Notice
            call Controller.reset() to re-initialize controller after this reset
        """

        if 0 == self._nvme.cap & (1ULL<<36):
            logging.warning("the controller does not supprt NSSR")
            return False

        pcie = self._nvme.pcie
        bdf = pcie._bdf.decode('utf-8')

        # notify ioworker to terminate, and wait all IO Qpair closed
        pcie._driver_cleanup()
        pcie._bind_driver(None)
        subprocess.call('echo 1 > "/sys/bus/pci/devices/%s/remove" 2> /dev/null || true' % bdf, shell=True)

        # nssr.nssrc: nvme subsystem reset
        logging.debug("nvme subsystem reset by NSSR.NSSRC")
        self._nvme[0x20] = 0x4e564d65  # "NVMe"

        # config spdk driver
        pcie._rescan()
        pcie._bind_driver('uio_pci_generic')
        logging.info("reset controller to use it after subsystem reset")
        return True


class NvmeEnumerateError(Exception):
    pass

class NvmeDeletionError(Exception):
    pass

cdef class Pcie(object):
    """Pcie class to access PCIe configuration and memory space

    # Parameters
        nvme (Controller): the nvme controller object of that subsystem
    """

    cdef d.ctrlr * _ctrlr
    cdef char _bdf[64]
    cdef char _vdid[64]
    cdef bint _backup
    cdef long _magic

    def __cinit__(self, addr):
        # pcie address, start with domain
        if not os.path.exists("/sys/bus/pci/devices/%s" % addr) and \
           not addr.startswith("0000:"):
            addr = "0000:"+addr
        bdf = addr.encode('utf-8')
        strncpy(self._bdf, bdf, strlen(bdf)+1)

        self._magic = 0x1243568790bacdfe
        self._ctrlr = d.nvme_init(bdf, 0)
        if self._ctrlr is NULL:
            raise NvmeEnumerateError("fail to create the controller")
        #print("create pcie: %x" % <unsigned long>self._ctrlr); sys.stdout.flush()
        self._backup = False

        #get vdid
        vdid = '%04x %04x' % (self.register(0, 2), self.register(2, 2))
        vdid = vdid.encode('utf-8')
        strncpy(self._vdid, vdid, strlen(vdid)+1)

    def close(self):
        """close to explictly release its resources instead of del"""

        #print("dealloc pcie: %x" % <unsigned long>self._ctrlr); sys.stdout.flush()
        if self._ctrlr is not NULL and self._backup is not True:
            ret = d.nvme_fini(self._ctrlr)
            if ret != 0:
                raise NvmeDeletionError("fail to close the controller")
        self._magic = 0
        self._ctrlr = NULL

    def _ctrlr_reinit(self):
        assert self._ctrlr is not NULL and self._backup is not True

        ret = d.nvme_fini(self._ctrlr)
        if ret != 0:
            raise NvmeDeletionError("fail to close the controller")

        self._ctrlr = d.nvme_init(self._bdf, 0)
        if self._ctrlr is NULL:
            raise NvmeEnumerateError("fail to create the controller")

    def _config(self, verify=None, ioworker_terminate=None):
        """config driver global setting

        # Parameters
            ioworker_terminate (bool): notify ioworker to terminate immediately. Default: None, means no change
        """

        cdef unsigned long c = d.driver_config_read()

        if verify == False:
            c &= 0xfffffffffffffffe
        elif verify == True:
            logging.error("obsoleted by Namespace.verify_enable()")
            c |= 1

        if ioworker_terminate == False:
            c &= 0xffffffffffffffef
        elif ioworker_terminate == True:
            c |= 0x10

        return d.driver_config(c)

    def _driver_cleanup(self):
        # notify ioworker to terminate, and wait all IO Qpair closed
        if d.driver_io_qpair_count(self._ctrlr):
            self._config(ioworker_terminate=True)
            logging.info("wait all qpair to be deleted")
            while d.driver_io_qpair_count(self._ctrlr):
                pass
            time.sleep(1)
            d.crc32_unlock_all(self._ctrlr)
            self._config(ioworker_terminate=False)

    def __getitem__(self, index):
        """access pcie config space by bytes."""
        cdef unsigned char value

        if isinstance(index, slice):
            return [self[ii] for ii in range(index.stop)[index]]
        elif isinstance(index, int):
            d.pcie_cfg_read8(d.pcie_init(self._ctrlr), &value, index)
            return value
        else:
            raise TypeError()

    def __setitem__(self, index, value):
        """set pcie config space by bytes."""
        if isinstance(index, int):
            d.pcie_cfg_write8(d.pcie_init(self._ctrlr), value, index)
        else:
            raise TypeError()

    def register(self, offset, byte_count=4):
        """access registers in pcie config space, and get its integer value.

        # Parameters
            offset (int): the offset (in bytes) of the register in the config space
            byte_count (int): the size (in bytes) of the register. Default: 4, dword

        Returns
            (int): the value of the register
        """

        assert byte_count <= 8, "support uptp 8-byte PCIe register access"
        value = bytes(self[offset:offset+byte_count])
        return int.from_bytes(value, 'little')

    def cap_offset(self, cap_id):
        """get the offset of a capability

        # Parameters
            cap_id (int): capability id

        Returns
            (int): the offset of the register, or None if the capability is not existed
        """

        next_offset = self.register(0x34, 1)
        while next_offset != 0:
            value = self.register(next_offset, 2)
            cid = value % 256
            cap_offset = next_offset
            next_offset = value>>8
            if cid == cap_id:
                return cap_offset

        logging.info("cannot find the capability %d" % cap_id)

    def _rescan(self, retry=5):
        bdf = self._bdf.decode('utf-8')

        # rescan device without kernel nvme driver
        subprocess.call('rmmod nvme 2> /dev/null || true', shell=True)
        subprocess.call('rmmod nvme_core 2> /dev/null || true', shell=True)
        subprocess.call('echo 1 > /sys/bus/pci/rescan 2> /dev/null || true', shell=True)

        # check if the device is online
        while not os.path.exists("/sys/bus/pci/devices/"+bdf):
            retry -= 1
            if retry == 0:
                logging.error("device lost: %s, retry %d" % (bdf, retry))
                return False
            time.sleep(1)
            logging.info("rescan the device: %s, retry %d" % (bdf, retry))
            subprocess.call('echo 1 > /sys/bus/pci/rescan 2> /dev/null || true', shell=True)

        logging.debug("find device on %s" % bdf)
        return True

    def _bind_driver(self, driver):
        bdf = self._bdf.decode('utf-8')
        vdid = self._vdid.decode('utf-8')

        if os.path.exists("/sys/bus/pci/devices/%s/driver" % bdf):
            logging.debug("unbind %s on %s" % (vdid, bdf))
            subprocess.call('echo "%s" > "/sys/bus/pci/devices/%s/driver/remove_id" 2> /dev/null || true' % (vdid, bdf), shell=True)
            subprocess.call('echo "%s" > "/sys/bus/pci/devices/%s/driver/unbind" 2> /dev/null || true' % (bdf, bdf), shell=True)

        if driver:
            subprocess.call('echo "%s" > "/sys/bus/pci/drivers/%s/new_id" 2> /dev/null || true' % (vdid, driver), shell=True)
            subprocess.call('echo "%s" > "/sys/bus/pci/drivers/%s/bind" 2> /dev/null || true' % (bdf, driver), shell=True)
            logging.debug("bind %s on %s" % (driver, bdf))

        self._rescan()

    def reset(self):  # pcie
        """reset this pcie device with hot reset

        Notice
            call Controller.reset() to re-initialize controller after this reset
        """

        bdf = self._bdf.decode('utf-8')
        dev_link = os.readlink("/sys/bus/pci/devices/"+bdf)
        port = dev_link.split('/')[-2]
        if 'pci' in port:
            port = port[3:]+":00.0"
        assert os.path.exists("/sys/bus/pci/devices/"+port)

        # notify ioworker to terminate, and wait all IO Qpair closed
        self._driver_cleanup()
        self._bind_driver(None)
        subprocess.call('echo 1 > "/sys/bus/pci/devices/%s/remove" 2> /dev/null || true' % bdf, shell=True)

        # hot reset by TS1 TS2
        ret = subprocess.check_output('setpci -s %s BRIDGE_CONTROL 2> /dev/null || true' % port, shell=True)
        bc = int(ret.strip(), 16)
        ret = subprocess.check_output('setpci -s %s BRIDGE_CONTROL=0x%x 2> /dev/null || true' % (port, bc|0x40), shell=True)
        time.sleep(0.01)
        ret = subprocess.check_output('setpci -s %s BRIDGE_CONTROL=0x%x 2> /dev/null || true' % (port, bc), shell=True)
        time.sleep(0.5)

        # config spdk driver
        self._rescan()
        self._bind_driver('uio_pci_generic')
        logging.info("reset controller to use it after pcie reset")
        return True

    @property
    def aspm(self):
        """config new ASPM Control:

        # Parameters
            control: ASPM control field in Link Control register:
                     b00: ASPM is disabled
                     b01: L0s
                     b10: L1
                     b11: L0s and L1
        """

        linkctrl_addr = self.cap_offset(0x10)+16
        return self.register(linkctrl_addr, 2) & 0x3

    @aspm.setter
    def aspm(self, control):
        assert control < 4 and control >= 0
        linkctrl_addr = self.cap_offset(0x10)+16
        linkctrl = self.register(linkctrl_addr, 2)
        self.__setitem__(linkctrl_addr, (linkctrl&0xfc)|control)

    @property
    def power_state(self):
        """config new power state:

        # Parameters
            state: new state of the PCIe device:
                   0: D0
                   1: D1
                   2: D2
                   3: D3hot
        """

        pmcsr_addr = self.cap_offset(1) + 4
        return self.register(pmcsr_addr, 4) & 0x3

    @power_state.setter
    def power_state(self, state):
        assert state < 4 and state >= 0
        pmcsr_addr = self.cap_offset(1) + 4
        pmcsr =  self.register(pmcsr_addr, 4)
        self.__setitem__(pmcsr_addr, (pmcsr&0xfc)|state)


class TcgError(Exception):
    pass

cdef class Tcg(object):
    """TCG class, for opal and pyrite tests"""

    cdef void* _dev

    def __cinit__(self, Controller nvme):
        self._dev = d.tcg_dev_init(nvme.pcie._ctrlr)
        if not self._dev:
            raise TcgError("tcg init fail")

    def close(self):
        """close to explictly release its resources instead of del"""

        d.tcg_dev_close(self._dev)

    def take_ownership(self, passwd=b'cranechu@gmail.com'):
        logging.debug("take ownership, %s" % passwd)
        if d.tcg_take_ownership(self._dev, passwd):
            raise TcgError("take_ownership fail")

    def revert_tper(self, passwd):
        logging.debug("revert, %s" % passwd)
        if d.tcg_revert_tper(self._dev, passwd):
            raise TcgError("revert_tper fail")

    def set_new_passwd(self, passwd, new_passwd, user=0):
        logging.debug("passwd, %s => %s" % (passwd, new_passwd))
        if d.tcg_set_passwd(self._dev, user, new_passwd, passwd):
            raise TcgError("set_new_passwd fail")

    def lock(self, passwd, state=2, user=0, range=0):
        """lock or unlock the range for the user

        # Parameters
            state (int): the lock state. 1: readonly, 2: rwlock, 4: unlock. default: 2
        """

        logging.debug("lock, %s, %d" % (passwd, state))
        if d.tcg_lock_unlock(self._dev, user, state, range, passwd):
            raise TcgError("lock/unlock fail")


cdef class Controller(object):
    """Controller class. Prefer to use fixture "nvme0" in test scripts.

    # Parameters
        addr (bytes): the bus/device/function address of the DUT, for example: \
                      b'01:00.0' (PCIe BDF address),  \
                      b'127.0.0.1' (TCP IP address).
        nvme_init_func (callable, bool, None): True: no nvme init process, None: default process, callable: user defined process function

    # Example
```python
        >>> n = Controller(Pcie('01:00.0'))
        >>> hex(n[0])     # CAP register
        '0x28030fff'
        >>> hex(n[0x1c])  # CSTS register
        '0x1'
        >>> n.id_data(23, 4, str)
        'TW0546VPLOH007A6003Y'
        >>> n.supports(0x18)
        False
        >>> n.supports(0x80)
        True
        >>> id_buf = Buffer()
        >>> n.identify().waitdone()
        >>> id_buf.dump(64)
        buffer
        00000000  a4 14 4b 1b 54 57 30 35  34 36 56 50 4c 4f 48 30  ..K.TW0546VPLOH0
        00000010  30 37 41 36 30 30 33 59  43 41 33 2d 38 44 32 35  07A6003YCA3-8D25
        00000020  36 2d 51 31 31 20 4e 56  4d 65 20 4c 49 54 45 4f  6-Q11 NVMe LITEO
        00000030  4e 20 32 35 36 47 42 20  20 20 20 20 20 20 20 20   N 256GB
        >>> n.cmdlog(2)
        driver.c:1451:log_cmd_dump: *NOTICE*: dump qpair 0, latest tail in cmdlog: 1
        driver.c:1462:log_cmd_dump: *NOTICE*: index 0, 2018-10-14 14:52:25.533708
        nvme_qpair.c: 118:nvme_admin_qpair_print_command: *NOTICE*: IDENTIFY (06) sqid:0 cid:0 nsid:1 cdw10:00000001 cdw11:00000000
        driver.c:1469:log_cmd_dump: *NOTICE*: index 0, 2018-10-14 14:52:25.534030
        nvme_qpair.c: 306:nvme_qpair_print_completion: *NOTICE*: SUCCESS (00/00) sqid:0 cid:95 cdw0:0 sqhd:0142 p:1 m:0 dnr:0
        driver.c:1462:log_cmd_dump: *NOTICE*: index 1, 1970-01-01 07:30:00.000000
        nvme_qpair.c: 118:nvme_admin_qpair_print_command: *NOTICE*: DELETE IO SQ (00) sqid:0 cid:0 nsid:0 cdw10:00000000 cdw11:00000000
        driver.c:1469:log_cmd_dump: *NOTICE*: index 1, 1970-01-01 07:30:00.000000
        nvme_qpair.c: 306:nvme_qpair_print_completion: *NOTICE*: SUCCESS (00/00) sqid:0 cid:0 cdw0:0 sqhd:0000 p:0 m:0 dnr:0
```
    """

    cdef Pcie pcie
    cdef Buffer hmb_buf
    cdef unsigned int _timeout
    cdef object nvme_init_func

    def __cinit__(self, pcie, nvme_init_func=None):
        assert type(pcie) is Pcie
        assert nvme_init_func is True or \
               nvme_init_func is None or \
               callable(nvme_init_func)

        self.pcie = pcie
        self._timeout = _cTIMEOUT*1000
        self.nvme_init_func = nvme_init_func

        # register timeout callback
        d.nvme_register_timeout_cb(self.pcie._ctrlr, timeout_driver_cb, self._timeout)
        logging.debug("nvme initialized: %s", self.pcie._bdf)

        # reset the device
        if nvme_init_func is not True:
            self._nvme_init()

    def _nvme_init(self):
        assert self.nvme_init_func is not True
        if self.nvme_init_func:
            # user defined nvme init process
            logging.info("run user defined nvme init")
            return self.nvme_init_func(self)

        # pynvme defined default nvme init process
        logging.debug("start nvme init process in pynvme")
        nvme0 = self
        timeout = ((nvme0.cap>>24) & 0xff)/2

        # 2. disable cc.en and wait csts.rdy to 0
        nvme0[0x14] = 0
        t = time.time()
        while not (nvme0[0x1c]&0x1) == 0:
            if time.time()-t > timeout:
                logging.error("csts.rdy timeout after cc.en=0, timeout: %ds" % timeout)
                raise NvmeEnumerateError("fail to init namespaces")

        # 3. set admin queue registers
        if 0 != nvme0.init_adminq():
            raise NvmeEnumerateError("fail to init admin queue")

        # 4. set register cc
        nvme0[0x14] = 0x00460000

        # 5. enable cc.en
        nvme0[0x14] = 0x00460001

        # 6. wait csts.rdy to 1
        t = time.time()
        while not (nvme0[0x1c]&0x1) == 1:
            if time.time()-t > timeout:
                logging.error("csts.rdy timeout after cc.en=1, timeout: %ds" % timeout)
                raise NvmeEnumerateError("fail to init namespaces")

        # 7. identify controller and all namespaces
        nvme0.identify(Buffer(4096)).waitdone()
        if nvme0.init_ns() < 0:
            # first try fail: warning, and retry
            warnings.warn("init namespaces fail")
            time.sleep(1)
            nvme0.identify(Buffer(4096)).waitdone()
            if nvme0.init_ns() < 0:
                # second try fail: error
                raise NvmeEnumerateError("fail to init namespaces")

        # 8. set/get num of queues
        nvme0.setfeatures(0x7, cdw11=0x00ff00ff).waitdone()
        nvme0.getfeatures(0x7).waitdone()

        # 9. send first aer cmd
        nvme0.aer()

    def enable_hmb(self):
        """enable HMB function"""

        hmb_size = self.id_data(275, 272)
        if hmb_size:
            self.hmb_buf = Buffer(4096*hmb_size)
            hmb_list_buf = Buffer(4096)
            hmb_list_buf[0:8] = self.hmb_buf.phys_addr.to_bytes(8, 'little')
            hmb_list_buf[8:12] = hmb_size.to_bytes(4, 'little')
            hmb_list_phys = hmb_list_buf.phys_addr
            self.setfeatures(0x0d,
                             cdw11=1,
                             cdw12=hmb_size,
                             cdw13=hmb_list_phys&0xffffffff,
                             cdw14=hmb_list_phys>>32,
                             cdw15=1).waitdone()

    def disable_hmb(self):
        """disable HMB function """

        self.setfeatures(0x0d, cdw11=0).waitdone()

    @property
    def latest_cid(self):
        return d.qpair_get_latest_cid(NULL, self.pcie._ctrlr)

    @property
    def addr(self):
        return self.pcie._bdf.decode('utf-8')

    @property
    def mdts(self):
        """max data transfer bytes"""

        max_size = 1*1024*1024  # limit data xfer size to 1MB
        page_size = (1UL<<(12+((self[4]>>16)&0xf)))
        mdts_shift = self.id_data(77)
        if mdts_shift:
            return min(page_size*(1UL<<mdts_shift), max_size)
        else:
            return max_size

    @property
    def cap(self):
        """64-bit CAP register of NVMe"""

        # it is a 64-bit readonly register
        cdef unsigned long value
        d.nvme_get_reg64(self.pcie._ctrlr, 0, &value)
        return value

    @property
    def _timeout_pynvme(self):
        # timeout signal in pynvme driver layer by seconds,
        # it's an assert fail, needs longer than drive's timeout
        return self._timeout//1000 + 20

    @property
    def timeout(self):
        """timeout value of this controller in milli-seconds.

        It is configurable by assigning new value in milli-seconds.
        """

        return self._timeout

    @timeout.setter
    def timeout(self, msec):
        """set new timeout time for this controller

        # Parameters
            msec (int): milli-seconds of timeout value
        """

        self._timeout = msec
        d.nvme_register_timeout_cb(self.pcie._ctrlr, timeout_driver_cb, self._timeout)

    def __getitem__(self, index):
        """read nvme registers in BAR memory space by dwords."""

        cdef unsigned int value

        assert index % 4 == 0, "only support 4-byte aligned NVMe register read"

        if isinstance(index, int):
            d.nvme_get_reg32(self.pcie._ctrlr, index, & value)
            if ~value == 0:
                raise SystemError()
            return value
        else:
            raise TypeError()

    def __setitem__(self, index, value):
        """write nvme registers in BAR memory space by dwords."""

        assert index % 4 == 0, "only support 4-byte aligned NVMe register write"

        if isinstance(index, int):
            d.nvme_set_reg32(self.pcie._ctrlr, index, value)
        else:
            raise TypeError()

    def init_adminq(self):
        """used by NVMe init process in scripts"""

        return d.nvme_set_adminq(self.pcie._ctrlr)

    def init_ns(self):
        """used by NVMe init process in scripts"""

        return d.nvme_set_ns(self.pcie._ctrlr)

    def cmdlog(self, count=0):
        """print recent commands and their completions.

        # Parameters
            count (int): the number of commands to print. Default: 0, to print the whole cmdlog
        """

        d.log_cmd_dump_admin(self.pcie._ctrlr, count)

    def reset(self):  # controller
        """controller reset: cc.en 1 => 0 => 1

        Notice
            Test scripts should delete all io qpairs before reset!
        """

        # notify ioworker to terminate, and wait all IO Qpair closed
        self.pcie._driver_cleanup()

        # reset driver: namespace is init by every test, so no need reinit
        time.sleep(1)
        self.pcie._ctrlr_reinit()
        self._nvme_init()

    def cmdname(self, opcode):
        """get the name of the admin command

        # Parameters
            opcode (int): the opcode of the admin command

        Returns
            (str): the command name
        """

        assert opcode < 256
        name = d.cmd_name(opcode, 0)
        return name.decode('ascii')

    def supports(self, opcode):
        """check if the admin command is supported

        # Parameters
            opcode (int): the opcode of the admin command

        Returns
            (bool): if the command is supported
        """

        assert opcode < 256*2 # *2 for nvm command set
        logpage_buf = Buffer(4096)
        self.getlogpage(5, logpage_buf).waitdone()
        return logpage_buf.data((opcode+1)*4-1, opcode*4) != 0

    def waitdone(self, expected=1):
        """sync until expected admin commands completion

        Notice
            Do not call this function in commands callback functions.

        # Parameters
            expected (int): expected commands to complete. Default: 1

        Returns
            (int): cdw0 of the last command
        """

        reaped = 0

        global _latest_cqe_cdw0
        global _reentry_flag
        assert _reentry_flag is False, "cannot re-entry waitdone() functions which may be caused by waitdone in callback functions, %d" % _reentry_flag
        _reentry_flag = True

        logging.debug("to reap %d admin commands" % expected)
        # some admin commands need long timeout limit, like: format,
        signal.alarm(self._timeout_pynvme)

        while reaped < expected:
            # wait admin Q pair done
            reaped += d.nvme_wait_completion_admin(self.pcie._ctrlr)

            # Since signals are delivered asynchronously at unpredictable
            # times, it is problematic to run any meaningful code directly
            # from the signal handler. Therefore, Python queues incoming
            # signals. The queue is processed later as part of the interpreter
            # loop. If your code is fully compiled, interpreter loop is never
            # executed and Python has no chance to check and run queued signal
            # handlers.
            # - from: https://stackoverflow.com/questions/16769870/cython-python-and-keyboardinterrupt-ignored
            PyErr_CheckSignals()
        signal.alarm(0)

        # in admin queue, may reap more than expected, because driver
        # will get admin CQ as many as possible
        assert reaped >= expected, \
            "not reap the exact completions! reaped %d, expected %d" % (reaped, expected)
        _reentry_flag = False
        return _latest_cqe_cdw0

    def abort(self, cid, sqid=0, cb=None):
        """abort admin commands

        # Parameters
            cid (int): command id of the command to be aborted
            sqid (int): sq id of the command to be aborted. Default: 0, to abort the admin command
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """

        self.send_admin_raw(None, 0x8,
                            nsid=0,
                            cdw10=(cid<<16)+sqid,
                            cdw11=0,
                            cdw12=0,
                            cdw13=0,
                            cdw14=0,
                            cdw15=0,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def identify(self, buf, nsid=0, cns=1, cb=None):
        """identify admin command

        # Parameters
            buf (Buffer): the buffer to hold the identify data
            nsid (int): nsid field in the command. Default: 0
            cns (int): cns field in the command. Default: 1
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """

        assert len(buf) >= 4096

        self.send_admin_raw(buf, 0x6,
                            nsid=nsid,
                            cdw10=cns,
                            cdw11=0,
                            cdw12=0,
                            cdw13=0,
                            cdw14=0,
                            cdw15=0,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def id_data(self, byte_end, byte_begin=None, type=int, nsid=0, cns=1):
        """get field in controller identify data

        # Parameters
            byte_end (int): the end byte number of this field, which is specified in NVMe spec. Included.
            byte_begin (int): the begin byte number of this field, which is specified in NVMe spec. It can be omitted if begin is the same as end when the field has only 1 byte. Included. Default: None, means only get 1 byte defined in byte_end
            type (type): the type of the field. It should be int or str. Default: int, convert to integer python object

        Returns
            (int or str): the data in the specified field
        """

        id_buf = Buffer(4096)
        self.identify(id_buf, nsid, cns).waitdone()
        return id_buf.data(byte_end, byte_begin, type)

    def getfeatures(self, fid, sel=0, buf=None,
                    cdw11=0, cdw12=0, cdw13=0, cdw14=0, cdw15=0,
                    cb=None):
        """getfeatures admin command

        # Parameters
            fid (int): feature id
            cdw11 (int): cdw11 in the command. Default: 0
            sel (int): sel field in the command. Default: 0
            buf (Buffer): the buffer to hold the feature data. Default: None
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """
        self.send_admin_raw(buf, 0xA,
                            nsid=1,
                            cdw10=(sel << 8)+fid,
                            cdw11=cdw11,
                            cdw12=cdw12,
                            cdw13=cdw13,
                            cdw14=cdw14,
                            cdw15=cdw15,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def setfeatures(self, fid, sv=0, buf=None,
                    cdw11=0, cdw12=0, cdw13=0, cdw14=0, cdw15=0,
                    cb=None):
        """setfeatures admin command

        # Parameters
            fid (int): feature id
            cdw11 (int): cdw11 in the command. Default: 0
            sv (int): sv field in the command. Default: 0
            buf (Buffer): the buffer to hold the feature data. Default: None
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """

        self.send_admin_raw(buf, 0x9,
                            nsid=0xffffffff,
                            cdw10=(sv << 31)+fid,
                            cdw11=cdw11,
                            cdw12=cdw12,
                            cdw13=cdw13,
                            cdw14=cdw14,
                            cdw15=cdw15,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def getlogpage(self, lid, buf, size=None, offset=0, nsid=0xffffffff, cb=None):
        """getlogpage admin command

        # Parameters
            lid (int): Log Page Identifier
            buf (Buffer): buffer to hold the log page
            size (int): size (in byte) of data to get from the log page,. Default: None, means the size is the same of the buffer
            offset (int): the location within a log page
            nsid (int): nsid field in the command. Default: 0xffffffff
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """

        if size is None:  size = len(buf)  # the same size of buffer
        assert size%4 == 0, "size must be dword aligned"
        assert offset%4 == 0, "offset must be dword aligned"

        dwords = (size >> 2) - 1  # zero-based dword number
        assert dwords >= 0
        assert dwords < 0x1_0000_0000, "32-bit field"
        assert offset >= 0
        assert offset < 0x1_0000_0000_0000_0000, "64-bit field"

        self.send_admin_raw(buf, 0x2,
                            nsid=nsid,
                            cdw10=((dwords & 0xffff) << 16) + lid,
                            cdw11=dwords >> 16,
                            cdw12=offset,
                            cdw13=offset >> 32,
                            cdw14=0,
                            cdw15=0,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def mi_send(self, opcode, dword0=0, dword1=0, buf=None, mtype=1, cb=None):
        """NVMe MI Send

        # Parameters
            opcode (int): MI opcode
            dword0 (int): MI request dword0
            dword1 (int): MI request dword1
            buf (Buffer): buffer to hold the request data
            mtype (int): MI message type. Default:1, MI command set
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """

        assert mtype == 1 or mtype == 4

        self.send_admin_raw(buf, 0x1d,
                            nsid=0,
                            cdw10=(mtype<<11)|4,
                            cdw11=opcode,
                            cdw12=dword0,
                            cdw13=dword1,
                            cdw14=0,
                            cdw15=0,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def mi_receive(self, opcode, dword0=0, dword1=0, buf=None, mtype=1, cb=None):
        """NVMe MI receive

        # Parameters
            opcode (int): MI opcode
            dword0 (int): MI request dword0
            dword1 (int): MI request dword1
            buf (Buffer): buffer to hold the response data
            mtype (int): MI message type. Default:1, MI command set
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """

        assert mtype == 1 or mtype == 4

        self.send_admin_raw(buf, 0x1e,
                            nsid=0,
                            cdw10=(mtype<<11)|4,
                            cdw11=opcode,
                            cdw12=dword0,
                            cdw13=dword1,
                            cdw14=0,
                            cdw15=0,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def format(self, lbaf=0, ses=0, nsid=1, cb=None):
        """format admin command

        Notice
            This Controller.format only send the admin command. Use Namespace.format to maintain pynvme internal data!

        # Parameters
            lbaf (int): lbaf (lba format) field in the command. Default: 0
            ses (int): ses field in the command. Default: 0, no secure erase
            nsid (int): nsid field in the command. Default: 1
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """

        assert ses < 8, "invalid format ses"
        assert lbaf < 16, "invalid format lbaf"

        self.send_admin_raw(None, 0x80,
                            nsid=nsid,
                            cdw10=(ses<<9) + lbaf,
                            cdw11=0,
                            cdw12=0,
                            cdw13=0,
                            cdw14=0,
                            cdw15=0,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)

        return self

    def sanitize(self, option=2, pattern=0, cb=None):
        """sanitize admin command

        # Parameters
            option (int): sanitize option field in the command
            pattern (int): pattern field in the command for overwrite method. Default: 0x5aa5a55a
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """

        self.send_admin_raw(None, 0x84,
                            nsid=0,
                            cdw10=option,
                            cdw11=pattern,
                            cdw12=0,
                            cdw13=0,
                            cdw14=0,
                            cdw15=0,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def dst(self, stc=1, nsid=0xffffffff, cb=None):
        """device self test (DST) admin command

        # Parameters
            stc (int): selftest code (stc) field in the command
            nsid (int): nsid field in the command. Default: 0xffffffff
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """

        self.send_admin_raw(None, 0x14,
                            nsid=nsid,
                            cdw10=stc,
                            cdw11=0,
                            cdw12=0,
                            cdw13=0,
                            cdw14=0,
                            cdw15=0,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def fw_download(self, buf, offset, size=None, cb=None):
        """firmware download admin command

        # Parameters
            buf (Buffer): the buffer to hold the firmware data
            offset (int): offset field in the command
            size (int): size field in the command. Default: None, means the size of the buffer
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """

        if size is None:  size = len(buf)  # the same size of buffer
        logging.debug("firmware image download, offset 0x%x, size %d" % (offset, size))
        self.send_admin_raw(buf, 0x11,
                            nsid=0,
                            cdw10=(size>>2)-1,  # zero-based dword number
                            cdw11=(offset>>2),  # unit is dword
                            cdw12=0,
                            cdw13=0,
                            cdw14=0,
                            cdw15=0,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def fw_commit(self, slot, action, cb=None):
        """firmware commit admin command

        # Parameters
            slot (int): firmware slot field in the command
            action (int): action field in the command
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """

        # no need to block invalid test parameters for DUT
        assert slot < 8, "invalid fw slot: %d" % slot
        assert action < 8, "invalid fw commit action: %d" % action

        logging.debug("firmware commit, slot %d, action %d" % (slot, action))
        self.send_admin_raw(None, 0x10,
                            nsid=0,
                            cdw10=(action<<3)+slot,
                            cdw11=0,
                            cdw12=0,
                            cdw13=0,
                            cdw14=0,
                            cdw15=0,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def downfw(self, filename, slot=0, action=1):
        """firmware download utility: by 4K, and activate in next reset

        # Parameters
            filename (str): the pathname of the firmware binary file to download
            slot (int): firmware slot field in the command. Default: 0, decided by device
            cb (function): callback function called at completion. Default: None

        Returns
        """

        logging.info("download firmware image %s to slot %d and activate" % (filename, slot))
        with open(filename, "rb") as f:
            buf = Buffer(4096)
            for i, chunk in enumerate(iter(lambda: f.read(4096), b'')):
                buf[:] = chunk
                self.fw_download(buf, 4096*i).waitdone()
        self.fw_commit(slot, action).waitdone()
        logging.info("download firmware completed")

    def aer(self, cb=None):
        """asynchorous event request admin command.

        Not suggested to use this command in scripts because driver manages to send and monitor aer commands. Scripts should register an aer callback function if it wants to handle aer, and use the fixture aer.

        # Parameters
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """

        self.send_admin_raw(None, 0xc,
                            nsid=0,
                            cdw10=0,
                            cdw11=0,
                            cdw12=0,
                            cdw13=0,
                            cdw14=0,
                            cdw15=0,
                            cb_func=aer_cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def security_receive(self, buf, spsp,
                         secp=1, nssf=0, size=None,
                         cb=None):
        """admin command: security receive

        # Parameters
            buf (Buffer): buffer of the data received
            spsp: SP specific 0/1, 16bit filed
            secp: security protocal, default 1, TCG
            nssf: NVMe security specific field: default 0, reserved
            size: size of the data to receive, default the same size of the buffer
            cb (function): callback function called at cmd completion
        """

        assert spsp < 64*1024
        assert not buf is None
        if size is None:  size = len(buf)  # the same size of buffer

        logging.debug("security receive, secp %d, spsp %d, nssf %d, size %d" %
                      (secp, spsp, nssf, size))
        self.send_admin_raw(buf, 0x82,
                            nsid=0,
                            cdw10=(secp<<24) + (spsp<<8) + (nssf),
                            cdw11=size,
                            cdw12=0,
                            cdw13=0,
                            cdw14=0,
                            cdw15=0,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def security_send(self, buf, spsp,
                      secp=1, nssf=0, size=None,
                      cb=None):
        """admin command: security send

        # Parameters
            buf (Buffer): buffer of the data sending
            spsp: SP specific 0/1, 16bit filed
            secp: security protocal, default 1, TCG
            nssf: NVMe security specific field: default 0, reserved
            size: size of the data to send, default the same size of the buffer
            cb (function): callback function called at cmd completion
        """

        assert spsp < 64*1024
        assert not buf is None
        if size is None:  size = len(buf)  # the same size of buffer

        logging.debug("security send, secp %d, spsp %d, nssf %d, size %d" %
                      (secp, spsp, nssf, size))
        self.send_admin_raw(buf, 0x81,
                            nsid=0,
                            cdw10=(secp<<24) + (spsp<<8) + (nssf),
                            cdw11=size,
                            cdw12=0,
                            cdw13=0,
                            cdw14=0,
                            cdw15=0,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    def send_cmd(self, opcode, buf=None, nsid=0,
                 cdw10=0, cdw11=0, cdw12=0,
                 cdw13=0, cdw14=0, cdw15=0,
                 cb=None):
        """send generic admin commands.

        This is a generic method. Scripts can use this method to send all kinds of commands, like Vendor Specific commands, and even not existed commands.

        # Parameters
            opcode (int): operate code of the command
            buf (Buffer): buffer of the command. Default: None
            nsid (int): nsid field of the command. Default: 0
            cb (function): callback function called at completion. Default: None

        Returns
            self (Controller)
        """

        self.send_admin_raw(buf, opcode,
                            nsid,
                            cdw10,
                            cdw11,
                            cdw12,
                            cdw13,
                            cdw14,
                            cdw15,
                            cb_func=cmd_cb,
                            cb_arg=<void*>cb)
        return self

    cdef send_admin_raw(self,
                        Buffer buf,
                        unsigned int opcode,
                        unsigned int nsid,
                        unsigned int cdw10,
                        unsigned int cdw11,
                        unsigned int cdw12,
                        unsigned int cdw13,
                        unsigned int cdw14,
                        unsigned int cdw15,
                        d.cmd_cb_func cb_func,
                        void* cb_arg):
        cdef void* ptr
        cdef size_t size

        if buf is None:
            ptr = NULL
            size = 0
        else:
            ptr = buf.ptr + buf.offset
            size = buf.size

        logging.debug("send admin command, opcode %xh" % opcode)
        ret = d.nvme_send_cmd_raw(self.pcie._ctrlr, NULL, opcode, nsid, ptr, size,
                                  cdw10, cdw11, cdw12, cdw13, cdw14, cdw15,
                                  cb_func, cb_arg)
        assert ret == 0, "error in submitting admin commands, %d" % ret
        return ret


class QpairCreationError(Exception):
    pass


class QpairDeletionError(Exception):
    pass


cdef class Qpair(object):
    """Qpair class. IO SQ and CQ are combinded as qpairs.

    # Parameters
        nvme (Controller): controller where to create the queue
        depth (int): SQ/CQ queue depth
        prio (int): when Weighted Round Robin is enabled, specify SQ priority here
    """

    cdef d.qpair * _qpair
    cdef Controller _nvme

    def __cinit__(self, Controller nvme,
                  unsigned int depth,
                  unsigned int prio=0):
        # create CQ and SQ
        assert depth>=2 and depth<=1024, "qdepth should be in [2, 1024]"
        assert depth <= (nvme.cap & 0xffff) + 1, "qdepth is larger than specification"

        self._qpair = d.qpair_create(nvme.pcie._ctrlr, prio, depth)
        if self._qpair is NULL:
            raise QpairCreationError("qpair create fail")
        self._nvme = nvme
        #print("create qpair: %x" % <unsigned long>self._qpair); sys.stdout.flush()

    def close(self):
        assert False, "use Qpair.delete()"

    def delete(self):
        """delete qpair's SQ and CQ"""

        #print("dealloc qpair: %x %x" % (<unsigned long>self._qpair, <unsigned long>self._nvme.pcie._ctrlr)); sys.stdout.flush()
        if self._nvme.pcie._magic == 0x1243568790bacdfe:
            if self._nvme.pcie._ctrlr is not NULL:
                if self._qpair is not NULL:
                    if d.qpair_free(self._qpair) != 0:
                        raise QpairDeletionError()
        self._qpair = NULL

    def __repr__(self):
        return "<qpair: %d>" % self.sqid

    @property
    def sqid(self):
        return d.qpair_get_id(self._qpair)

    @property
    def latest_cid(self):
        return d.qpair_get_latest_cid(self._qpair, self._nvme.pcie._ctrlr)

    def cmdlog(self, count=0):
        """print recent IO commands and their completions in this qpair.

        # Parameters
            count (int): the number of commands to print. Default: 0, to print the whole cmdlog
        """

        d.log_cmd_dump(self._qpair, count)

    def msix_clear(self):
        d.intc_clear(self._qpair)

    def msix_isset(self):
        return d.intc_isset(self._qpair)

    def msix_mask(self):
        d.intc_mask(self._qpair)

    def msix_unmask(self):
        d.intc_unmask(self._qpair)

    def waitdone(self, expected=1):
        """sync until expected IO commands completion

        Notice
            Do not call this function in commands callback functions.

        # Parameters
            expected (int): expected commands to complete. Default: 1

        Returns
            (int): cdw0 of the last command
        """

        reaped = 0

        global _latest_cqe_cdw0
        global _reentry_flag
        assert _reentry_flag is False, "cannot re-entry waitdone() functions which may be caused by waitdone in callback functions, %d" % _reentry_flag
        _reentry_flag = True

        logging.debug("to reap %d io commands, sqid %d" % (expected, self.sqid))
        signal.alarm(self._nvme._timeout_pynvme)

        while reaped < expected:
            # wait IO Q pair done, max 8 cpl in one time
            reaped += d.qpair_wait_completion(self._qpair, 1)
            PyErr_CheckSignals()
        signal.alarm(0)

        assert reaped == expected, \
            "not reap the exact completions! reaped %d, expected %d" % (reaped, expected)
        _reentry_flag = False
        return _latest_cqe_cdw0


class NamespaceCreationError(Exception):
    pass


class NamespaceDeletionError(Exception):
    pass


cdef class Namespace(object):
    """Namespace class.

    # Parameters
        nvme (Controller): controller where to create the queue
        nsid (int): nsid of the namespace. Default 1
        nlba_verify (long): number of LBAs where data verificatoin is enabled. Default 0, the whole namespace
    """

    cdef Controller _nvme
    cdef d.namespace * _ns
    cdef unsigned int _nsid
    cdef unsigned int sector_size
    cdef unsigned long nlba_verify

    def __cinit__(self, Controller nvme, unsigned int nsid=1, unsigned long nlba_verify=0):
        logging.debug("initialize namespace nsid %d" % nsid)
        self._nvme = nvme
        self._nsid = nsid
        self._ns = d.ns_init(nvme.pcie._ctrlr, nsid, nlba_verify)
        if self._ns is NULL:
            raise NamespaceCreationError()
        self.sector_size = d.ns_get_sector_size(self._ns)
        self.nlba_verify = nlba_verify
        #print("created namespace: 0x%x" % <unsigned long>self._ns); sys.stdout.flush()

    def close(self):
        """close to explictly release its resources instead of del"""

        #print("dealloc namespace: 0x%x" % <unsigned long>self._ns); sys.stdout.flush()
        if self._nvme.pcie._magic == 0x1243568790bacdfe:
            if self._nvme.pcie._ctrlr is not NULL:
                self._ns = d.nvme_get_ns(self._nvme.pcie._ctrlr, self._nsid)
                if self._ns is not NULL:
                    if d.ns_fini(self._ns) != 0:
                        raise NamespaceDeletionError()
        self._ns = NULL

    @property
    def nsid(self):
        """id of the namespace"""
        return self._nsid

    @property
    def capacity(self):
        """bytes of namespace capacity"""
        return self.id_data(63, 48)

    def cmdname(self, opcode):
        """get the name of the IO command

        # Parameters
            opcode (int): the opcode of the IO command

        Returns
            (str): the command name
        """

        assert opcode < 256
        name = d.cmd_name(opcode, 1)
        return name.decode('ascii')

    def supports(self, opcode):
        """check if the IO command is supported

        # Parameters
            opcode (int): the opcode of the IO command

        Returns
            (bool): if the command is supported
        """

        assert opcode < 256
        return self._nvme.supports(256+opcode)

    def id_data(self, byte_end, byte_begin=None, type=int):
        """get field in namespace identify data

        # Parameters
            byte_end (int): the end byte number of this field, which is specified in NVMe spec. Included.
            byte_begin (int): the begin byte number of this field, which is specified in NVMe spec. It can be omitted if begin is the same as end when the field has only 1 byte. Included. Default: None, means only get 1 byte defined in byte_end
            type (type): the type of the field. It should be int or str. Default: int, convert to integer python object

        Returns
            (int or str): the data in the specified field
        """

        return self._nvme.id_data(byte_end, byte_begin, type, self._nsid, 0)

    def verify_enable(self, enable=True):
        """enable or disable the inline verify function of the namespace

        # Parameters
            enable (bool): enable or disable the verify function

        Returns
            (bool): if it is enabled successfully
        """

        self._ns = d.nvme_get_ns(self._nvme.pcie._ctrlr, self._nsid)
        return d.ns_verify_enable(self._ns, enable)

    def format(self, data_size=512, meta_size=0, ses=0):
        """change the format of this namespace

        Notice
            Namespace.format() not only sends the admin command, but also updates driver to activate new format immediately. Recommend to use this API to do format. Close and re-create namespace when lba format is changed. 

        # Parameters
            data_size (int): data size. Default: 512
            meta_size (int): meta data size. Default: 0
            ses (int): ses field in the command. Default: 0, no secure erase

        Returns
            int: cdw0 of the format admin command
        """

        orig_timeout = self._nvme.timeout
        self._nvme.timeout = max(orig_timeout, 100*1000)

        # only format this one namespace
        lbaf = self.get_lba_format(data_size, meta_size)
        cdw0 = self._nvme.format(lbaf, ses, self._nsid).waitdone()
        self._ns = d.nvme_get_ns(self._nvme.pcie._ctrlr, self._nsid)
        if 0 != d.ns_refresh(self._ns, self._nsid, self._nvme.pcie._ctrlr):
            raise NamespaceCreationError()

        self._nvme.timeout = orig_timeout
        return cdw0

    def get_lba_format(self, data_size=512, meta_size=0):
        """find the lba format by its data size and meta data size

        # Parameters
            data_size (int): data size. Default: 512
            meta_size (int): meta data size. Default: 0

        Returns
            (int or None): the lba format has the specified data size and meta data size
        """

        for fid in range(16):
            format_support = self.id_data(128+fid*4+3, 128+fid*4)
            if data_size == (1<<((format_support>>16)&0xff)) and \
               meta_size == (format_support&0xffff):
                return fid

    def ioworker(self, io_size=8, lba_step=None, lba_align=None,
                 lba_random=True, read_percentage=100,
                 op_percentage=None, time=0, qdepth=64,
                 region_start=0, region_end=0xffffffffffffffff,
                 iops=0, io_count=0, lba_start=0, qprio=0,
                 distribution=None, ptype=0xbeef, pvalue=100,
                 io_sequence=None,
                 output_io_per_second=None,
                 output_percentile_latency=None,
                 output_cmdlog_list=None):
        """workers sending different read/write IO on different CPU cores.

        User defines IO characteristics in parameters, and then the ioworker
        executes without user intervesion, until the test is completed. IOWorker
        returns some statistic data at last.

        User can start multiple IOWorkers, and they will be binded to different
        CPU cores. Each IOWorker creates its own Qpair, so active IOWorker counts
        is limited by maximum IO queues that DUT can provide.

        Each ioworker can run upto 24 hours.

        # Parameters
            io_size (short, range, list, dict): IO size, unit is LBA. It can be a fixed size, or a range or list of size, or specify ratio in the dict if they are not evenly distributed. 1base. Default: 8, 4K
            lba_step (short): valid only for sequential read/write, jump to next LBA by the step. Default: None, same as io_size, continous IO.
            lba_align (short): IO alignment, unit is LBA. Default: None: same as io_size when it < 4K, or it is 4K
            lba_random (int, bool): percentage of radom io, or True if sending IO with all random starting LBA. Default: True
            read_percentage (int): sending read/write mixed IO, 0 means write only, 100 means read only. Default: 100. Obsoloted by op_percentage
            op_percentage (dict): opcode of commands sent in ioworker, and their percentage. Output: real io counts sent in ioworker. Default: None, fall back to read_percentage
            time (int): specified maximum time of the IOWorker in seconds, up to 1000*3600. Default:0, means no limit
            qdepth (int): queue depth of the Qpair created by the IOWorker, up to 1024. 1base. Default: 64
            region_start (long): sending IO in the specified LBA region, start. Default: 0
            region_end (long): sending IO in the specified LBA region, end but not include. Default: 0xffff_ffff_ffff_ffff
            iops (int): specified maximum IOPS. IOWorker throttles the sending IO speed. Default: 0, means no limit
            io_count (long): specified maximum IO counts to send. Default: 0, means no limit
            lba_start (long): the LBA address of the first command. Default: 0, means start from region_start
            qprio (int): SQ priority. Default: 0, as Round Robin arbitration
            distribution (list(int)): distribute 10,000 IO to 100 sections. Default: None
            pvalue (int): data pattern value. Refer to data pattern in class `Buffer`. Default: 100 (100%)
            ptype (int): data pattern type. Refer to data pattern in class `Buffer`. Default: 0xbeef (random data)
            io_sequence (list): io sequence of captured trace from real workload. Ignore other input parameters when io_sequence is given. Default: None
            output_io_per_second (list): list to hold the output data of io_per_second. Default: None, not to collect the data
            output_percentile_latency (dict): dict of io counter on different percentile latency. Dict key is the percentage, and the value is the latency in micro-second. Default: None, not to collect the data
            output_cmdlog_list (list): list of dwords of lastest commands completed in the ioworker. Default: None, not to collect the data

        Returns
            ioworker instance
        """

        assert not (io_sequence==None and time==0 and io_count==0), "when to stop the ioworker?"
        assert qdepth>=2 and qdepth<=1024, "qdepth should be in [2, 1024]"
        assert qdepth <= (self._nvme.cap & 0xffff) + 1, "qdepth is larger than specification"
        assert region_start < region_end, "region end is not included"
        assert time <= 1000*3600ULL, "worker needs a rest :)"
        assert read_percentage <= 100, "read percentage is less than 100"
        assert iops==0 or iops >= qdepth, "iops must be larger than qdepth"

        if op_percentage is None:
            op_percentage = {2: read_percentage, 1: 100-read_percentage}

        # verify op percentage
        sum_percentage = 0
        for _, k in enumerate(op_percentage):
            sum_percentage += op_percentage[k]
        assert sum_percentage == 100, "op_percentage definition error"

        if type(lba_random) is bool:
            if lba_random == True: lba_random = 100
            if lba_random == False: lba_random = 0
        assert type(lba_random) is int, "lba_random is a percentage, int"
        assert lba_random >= 0 and lba_random <= 100, "lba_random is a percentage, 0-100"

        if lba_random < 100:
            assert type(io_size) is int, "sequential workload cannot work with complex io_size"

        # io_size should be smaller than test region
        if type(io_size) is int:
            assert io_size <= region_end-region_start, "region is smaller than IO!"
        else:
            assert max(list(io_size)) < region_end-region_start, "region is smaller than IO"

        # lba_step works with pure sequential workload only
        if lba_step is None:
            if lba_random < 100:
                lba_step = io_size
            else:
                lba_step = 0
        assert lba_step > -0x8000, "io size or step is too large"
        assert lba_step < 0x8000, "io size or step is too large"

        # convert any possible io_size input to dict
        if isinstance(io_size, int):
            io_size = [io_size, ]
        if isinstance(io_size, range):
            io_size = list(io_size)
        if isinstance(io_size, list):
            io_size = {i : 1 for i in io_size}
        assert isinstance(io_size, dict)
        assert 0 not in io_size.keys(), "io_size cannot be 0"

        # set default alignment if it is specified
        if lba_align is None:
            lba_align = [min(s, 8) for s in io_size.keys()]
        if isinstance(lba_align, int):
            lba_align = [lba_align, ]
        assert isinstance(lba_align, list)
        assert 0 not in lba_align, "lba_align cannot be 0"

        pciaddr = self._nvme.pcie._bdf
        return _IOWorker(pciaddr, self._nsid, self.nlba_verify,
                         lba_start, lba_step, io_size,
                         lba_align, lba_random, region_start, region_end,
                         op_percentage, iops, io_count, time, qdepth, qprio,
                         distribution, pvalue, ptype, io_sequence,
                         output_io_per_second,
                         output_percentile_latency,
                         output_cmdlog_list)

    def read(self, qpair, buf, lba, lba_count=1, io_flags=0,
             dword13=0, dword14=0, dword15=0, cb=None):
        """read IO command

        Notice
            buf cannot be released before the command completes.

        # Parameters
            qpair (Qpair): use the qpair to send this command
            buf (Buffer): the data buffer of the command, meta data is not supported.
            lba (int): the starting lba address, 64 bits
            lba_count (int): the lba count of this command, 16 bits. Default: 1
            io_flags (int): io flags defined in NVMe specification, 16 bits. Default: 0
            dword13 (int): command SQE dword13
            dword14 (int): command SQE dword14
            dword15 (int): command SQE dword15
            cb (function): callback function called at completion. Default: None

        Returns
            qpair (Qpair): the qpair used to send this command, for ease of chained call
        """

        assert buf is not None, "no buffer allocated"

        self.send_read_write(2, qpair, buf, lba, lba_count,
                             io_flags, cmd_cb, <void*>cb,
                             dword13, dword14, dword15)
        return qpair

    def write(self, qpair, buf, lba, lba_count=1, io_flags=0,
              dword13=0, dword14=0, dword15=0, cb=None):
        """write IO command

        Notice
            buf cannot be released before the command completes.

        # Parameters
            qpair (Qpair): use the qpair to send this command
            buf (Buffer): the data buffer of the write command, meta data is not supported.
            lba (int): the starting lba address, 64 bits
            lba_count (int): the lba count of this command, 16 bits
            io_flags (int): io flags defined in NVMe specification, 16 bits. Default: 0
            dword13 (int): command SQE dword13
            dword14 (int): command SQE dword14
            dword15 (int): command SQE dword15
            cb (function): callback function called at completion. Default: None

        Returns
            qpair (Qpair): the qpair used to send this command, for ease of chained call
        """

        assert buf is not None, "no buffer allocated"

        self.send_read_write(1, qpair, buf, lba, lba_count,
                             io_flags, cmd_cb, <void*>cb,
                             dword13, dword14, dword15)
        return qpair

    def dsm(self, qpair, buf, range_count, attribute=0x4, cb=None):
        """data-set management IO command

        Notice
            buf cannot be released before the command completes.

        # Parameters
            qpair (Qpair): use the qpair to send this command
            buf (Buffer): the buffer of the lba ranges. Use buffer.set_dsm_range to prepare the buffer.
            range_count (int): the count of lba ranges in the buffer
            attribute (int): attribute field of the command. Default: 0x4, as deallocation/trim
            cb (function): callback function called at completion. Default: None

        Returns
            qpair (Qpair): the qpair used to send this command, for ease of chained call

        # Raises
            SystemError: the command fails
        """

        assert buf is not None, "no range prepared"
        assert len(buf) <= 4096, "most range count is 256B"

        # send the command
        self.send_io_raw(qpair, buf, 9, self._nsid,
                         range_count-1, attribute,
                         0, 0, 0, 0,
                         cmd_cb, <void*>cb)
        return qpair

    def verify(self, qpair, lba, lba_count=1, io_flags=0, cb=None):
        """verify IO command

        # Parameters
            qpair (Qpair): use the qpair to send this command
            lba (int): the starting lba address, 64 bits
            lba_count (int): the lba count of this command, 16 bits. Default: 1
            io_flags (int): io flags defined in NVMe specification, 16 bits. Default: 0
            cb (function): callback function called at completion. Default: None

        Returns
            qpair (Qpair): the qpair used to send this command, for ease of chained call

        # Raises
            SystemError: the read command fails
        """

        self.send_io_raw(qpair, None, 0xc, self._nsid,
                         lba&0xffffffff, lba>>32,
                         (lba_count-1)|(io_flags<<16),
                         0, 0, 0,
                         cmd_cb, <void*>cb)
        return qpair

    def compare(self, qpair, buf, lba, lba_count=1, io_flags=0, cb=None):
        """compare IO command

        Notice
            buf cannot be released before the command completes.

        # Parameters
            qpair (Qpair): use the qpair to send this command
            buf (Buffer): the data buffer of the command, meta data is not supported.
            lba (int): the starting lba address, 64 bits
            lba_count (int): the lba count of this command, 16 bits. Default: 1
            io_flags (int): io flags defined in NVMe specification, 16 bits. Default: 0
            cb (function): callback function called at completion. Default: None

        Returns
            qpair (Qpair): the qpair used to send this command, for ease of chained call

        # Raises
            SystemError: the command fails
        """

        assert buf is not None, "no buffer allocated"

        self.send_io_raw(qpair, buf, 5, self._nsid,
                         lba&0xffffffff, lba>>32,
                         (lba_count-1)|(io_flags<<16),
                         0, 0, 0,
                         cmd_cb, <void*>cb)
        return qpair

    def flush(self, qpair, cb=None):
        """flush IO command

        # Parameters
            qpair (Qpair): use the qpair to send this command
            cb (function): callback function called at completion. Default: None

        Returns
            qpair (Qpair): the qpair used to send this command, for ease of chained call

        # Raises
            SystemError: the command fails
        """

        self.send_io_raw(qpair, None, 0, self._nsid,
                         0, 0, 0, 0, 0, 0,
                         cmd_cb, <void*>cb)
        return qpair

    def write_uncorrectable(self, qpair, lba, lba_count=1, cb=None):
        """write uncorrectable IO command

        # Parameters
            qpair (Qpair): use the qpair to send this command
            lba (int): the starting lba address, 64 bits
            lba_count (int): the lba count of this command, 16 bits. Default: 1
            cb (function): callback function called at completion. Default: None

        Returns
            qpair (Qpair): the qpair used to send this command, for ease of chained call

        # Raises
            SystemError: the command fails
        """

        self.send_io_raw(qpair, None, 4, self._nsid,
                         lba&0xffffffff, lba>>32,
                         lba_count-1,
                         0, 0, 0,
                         cmd_cb, <void*>cb)
        return qpair

    def write_zeroes(self, qpair, lba, lba_count=1, io_flags=0, cb=None):
        """write zeroes IO command

        # Parameters
            qpair (Qpair): use the qpair to send this command
            lba (int): the starting lba address, 64 bits
            lba_count (int): the lba count of this command, 16 bits. Default: 1
            io_flags (int): io flags defined in NVMe specification, 16 bits. Default: 0
            cb (function): callback function called at completion. Default: None

        Returns
            qpair (Qpair): the qpair used to send this command, for ease of chained call

        # Raises
            SystemError: the command fails
        """

        self.send_io_raw(qpair, None, 8, self._nsid,
                         lba&0xffffffff, lba>>32,
                         (lba_count-1)|(io_flags<<16),
                         0, 0, 0,
                         cmd_cb, <void*>cb)
        return qpair

    cdef send_read_write(self,
                         unsigned char opcode,
                         Qpair qpair,
                         Buffer buf,
                         unsigned long lba,
                         unsigned int lba_count,
                         unsigned int io_flags,
                         d.cmd_cb_func cb_func,
                         void* cb_arg,
                         unsigned int dword13,
                         unsigned int dword14,
                         unsigned int dword15):
        assert lba_count <= 64*1024, "exceed lba count limit"
        self._ns = d.nvme_get_ns(self._nvme.pcie._ctrlr, self._nsid)

        if buf is None:
            ptr = NULL
            size = 0
        else:
            ptr = buf.ptr + buf.offset
            size = buf.size

        ret = d.ns_cmd_io(opcode, self._ns, qpair._qpair,
                          ptr, size,
                          lba, lba_count, io_flags<<16,
                          cb_func, cb_arg,
                          dword13, dword14, dword15)
        assert ret == 0, "error in submitting read write commands: %d" % ret
        return ret

    def send_cmd(self, opcode, qpair, buf=None, nsid=1,
                 cdw10=0, cdw11=0, cdw12=0,
                 cdw13=0, cdw14=0, cdw15=0,
                 cb=None):
        """send generic IO commands.

        This is a generic method. Scripts can use this method to send all kinds of commands, like Vendor Specific commands, and even not existed commands.

        # Parameters
            opcode (int): operate code of the command
            qpair (Qpair): qpair used to send this command
            buf (Buffer): buffer of the command. Default: None
            nsid (int): nsid field of the command. Default: 0
            cdw1x (int): command SQE dword10 - dword15
            cb (function): callback function called at completion. Default: None

        Returns
            qpair (Qpair): the qpair used to send this command, for ease of chained call
        """

        self.send_io_raw(qpair, buf, opcode,
                         nsid,
                         cdw10,
                         cdw11,
                         cdw12,
                         cdw13,
                         cdw14,
                         cdw15,
                         cb_func=cmd_cb,
                         cb_arg=<void*>cb)
        return qpair

    cdef send_io_raw(self,
                     Qpair qpair,
                     Buffer buf,
                     unsigned int opcode,
                     unsigned int nsid,
                     unsigned int cdw10,
                     unsigned int cdw11,
                     unsigned int cdw12,
                     unsigned int cdw13,
                     unsigned int cdw14,
                     unsigned int cdw15,
                     d.cmd_cb_func cb_func,
                     void* cb_arg):
        if buf is None:
            ptr = NULL
            size = 0
        else:
            ptr = buf.ptr + buf.offset
            size = buf.size

        ret = d.nvme_send_cmd_raw(self._nvme.pcie._ctrlr, qpair._qpair, opcode,
                                  nsid, ptr, size, cdw10, cdw11, cdw12,
                                  cdw13, cdw14, cdw15, cb_func, cb_arg)
        assert ret == 0, "error in submitting io commands, %d" % ret
        return ret


class _DotDict(dict):
    """utility class to access dict members by . operation"""
    def __init__(self, *args, **kwargs):
        super(_DotDict, self).__init__(*args, **kwargs)
        self.__dict__ = self


class _IOWorker(object):
    """A process-worker executing user functions. Use its wrapper function Namespace.ioworker() in scripts. """

    target_start_time = 0

    def __init__(self, pciaddr, nsid, nlba_verify,
                 lba_start, lba_step, lba_size,
                 lba_align, lba_random, region_start, region_end,
                 op_percentage, iops, io_count, time, qdepth, qprio,
                 distribution, pvalue, ptype, io_sequence,
                 output_io_per_second,
                 output_percentile_latency,
                 output_cmdlog_list):
        # queue for returning result
        self.q = _mp.Queue()

        # lock for processes sync
        self.l = _mp.Lock()

        # create the child process
        self.p = _mp.Process(target = self._ioworker,
                             args = (self.q, self.l, pciaddr,
                                     nsid, nlba_verify,
                                     int(random.random()*0xffffffff),
                                     lba_start, lba_step, lba_size,
                                     lba_align, lba_random,
                                     region_start, region_end,
                                     op_percentage,
                                     iops, io_count, time, qdepth, qprio,
                                     distribution, pvalue, ptype,
                                     io_sequence,
                                     output_io_per_second,
                                     output_percentile_latency,
                                     output_cmdlog_list))
        self.output_io_per_second = output_io_per_second
        self.output_percentile_latency = output_percentile_latency
        self.output_cmdlog_list = output_cmdlog_list
        self.op_counter = op_percentage
        self.p.daemon = True

    def start(self):
        """Start the worker's process"""
        self.p.start()
        return self

    @property
    def running(self):
        """check the state of the ioworker

        Returns
            (bool): ioworker is running or not.
        """

        return self.q.empty() if hasattr(self, 'q') else False

    def find_percentile_latency(self, k, output_io_per_latency):
        target = sum(output_io_per_latency) * k // 100
        total = 0
        for l, c in enumerate(output_io_per_latency):
            total += c
            if total >= target:
                return l
        assert False, "should find the latency in the loop"

    def close(self):
        """Wait the ioworker's process finish

        Wait the worker process complete, and get the return report data
        """

        # get data from queue before joinging the subprocess, otherwise deadlock
        childpid, error, rets, \
            output_io_per_second, \
            output_io_per_latency, \
            output_cmdlog_list, \
            op_counter = self.q.get()
        self.p.join()

        _error_strings = (
            "no error",  #0
            "init fail in pyx",  #-1
            "io_size is larger than MDTS",  #-2
            "io timeout",  #-3
            "ioworker timeout", #-4
            "buffer pool alloc fail", #-5
            "illegal error code"
        )
        error_str = _error_strings[min(len(_error_strings)-1, -error)]
        if error != 0:
            warnings.warn("ioworker host ERROR %d: %s" % (error, error_str))

        rets = _DotDict(rets)
        if rets.error != 0:
            warnings.warn("ioworker device respond an ERROR status: %02x/%02x" %
                          ((rets.error>>8)&0x7, rets.error&0xff))

        # transfer output table back: driver => script
        if self.output_io_per_second is not None:
            assert len(self.output_io_per_second) == 0
            self.output_io_per_second += output_io_per_second[:rets['mseconds']//1000]
            rets['iops_consistency'] = self.iops_consistency()

        # transfer output table back: driver => script
        if output_io_per_latency is not None:
            rets['latency_distribution'] = output_io_per_latency

        if output_io_per_latency is not None:
            # calculate percentile latencies
            for i, k in enumerate(self.output_percentile_latency):
                assert k>0 and k<100, "percentile should be in (0, 100)"
                self.output_percentile_latency[k] = \
                    self.find_percentile_latency(k, output_io_per_latency)

        # transfer output table back: driver => script
        if self.output_cmdlog_list:
            for i, v in enumerate(output_cmdlog_list):
                self.output_cmdlog_list[i] = v

        # transfer output table back: driver => script
        # update counter to op_percentage
        for _, k in enumerate(self.op_counter):
            self.op_counter[k] = op_counter[k]-self.op_counter[k]

        # back-compatibility
        rets['io_count_write'] = self.op_counter[1] if 1 in op_counter else 0
        if rets.mseconds:
            rets.cpu_usage = rets.cpu_usage/rets.mseconds
        else:
            rets.cpu_usage = 0

        # release child process resources
        del self.q
        for f in glob.glob("/var/run/dpdk/spdk%d/fbarray_memseg*%d" %
                           (os.getpid(), childpid)):
            os.remove(f)

        return rets

    def iops_consistency(self, slowest_percentage=99.9):
        assert self.output_io_per_second is not None, "iops consistency data is not collected"
        assert slowest_percentage > 0, "the percentage must be larger than 0"
        assert slowest_percentage < 100, "the percentage must be smaller than 100"
        assert self.output_io_per_second, "output list is empty"
        average = sum(self.output_io_per_second)/len(self.output_io_per_second)
        index = int(len(self.output_io_per_second)*slowest_percentage)//100
        return sorted(self.output_io_per_second, reverse=True)[index]/average

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        assert exc_value is None, "ioworker exits with exception: %s" % exc_value
        self.close()
        return True

    def _ioworker(self, rqueue, locker, pciaddr, nsid, nlba_verify, seed,
                  lba_start, lba_step, lba_size, lba_align, lba_random,
                  region_start, region_end, op_percentage,
                  iops, io_count, seconds, qdepth, qprio,
                  distribution, pvalue, ptype, io_sequence,
                  output_io_per_second,
                  output_percentile_latency,
                  output_cmdlog_list):
        cdef d.ioworker_args args
        cdef d.ioworker_rets rets
        cdef int error = 0
        output_io_per_latency = None

        try:
            # register events in worker's processor
            # CTRL-c to exit
            signal.signal(signal.SIGINT, _interrupt_handler)
            # timeout
            signal.signal(signal.SIGALRM, _timeout_signal_handler)

            # setup random seed
            d.driver_srand(seed)
            random.seed(seed)

            # init var
            _reentry_flag_init()
            memset(&args, 0, sizeof(args))
            memset(&rets, 0, sizeof(rets))

            # setup lba_size lists
            assert isinstance(lba_size, dict)
            assert isinstance(lba_align, list)
            assert len(lba_size) == len(lba_align), "size and align not match"
            args.lba_size_max = max(lba_size.keys())
            args.lba_align_max = max(lba_align)
            args.lba_size_ratio_sum = sum(lba_size[i] for i in lba_size)
            assert args.lba_size_ratio_sum <= 10000, "please simplify the io_size ratios"
            args.lba_size_list = <unsigned int*>PyMem_Malloc(len(lba_size)*sizeof(unsigned int))
            args.lba_size_list_len = len(lba_size)
            args.lba_size_list_ratio = <unsigned int*>PyMem_Malloc(len(lba_size)*sizeof(unsigned int))
            args.lba_size_list_align = <unsigned int*>PyMem_Malloc(len(lba_size)*sizeof(unsigned int))
            if not args.lba_size_list or \
               not args.lba_size_list_ratio or \
               not args.lba_size_list_align:
                raise MemoryError()
            for i, io_size in enumerate(lba_size):
                args.lba_size_list[i] = io_size
                args.lba_size_list_ratio[i] = lba_size[io_size]
                args.lba_size_list_align[i] = lba_align[i]
                assert io_size < 0x10000, "io_size is a 16bit-field in commands"
                assert lba_align[i] < 0x10000, "io_size is a 16bit-field in commands"

            # check distribution
            if distribution is not None:
                assert region_start == 0, "distribution has to be on the full region"
                assert region_end == 0xffffffffffffffff, "distribution has to be on the full region"
                assert len(distribution) == 100, "distribution on 100 equal sections"
                assert sum(distribution) == 10000, "distribute 10000 IO on 100 sections"
                assert lba_random == 100, "distribution has to be all random IO"
                args.distribution = <unsigned int*>PyMem_Malloc(100*sizeof(unsigned int))
                if not args.distribution:
                    raise MemoryError()
                for i in range(100):
                    args.distribution[i] = distribution[i]

            if seconds == 0:
                # collect upto 1000hr IOPS data
                seconds = 1000*3600ULL

            if io_sequence:
                assert iops==0, "run sequence instead of fixed iops workload"
                args.io_sequence_len = len(io_sequence)
                args.io_sequence = <d.ioworker_ioseq*>PyMem_Malloc(len(io_sequence)*sizeof(d.ioworker_ioseq))
                if not args.io_sequence:
                    raise MemoryError()
                for i, line in enumerate(io_sequence):
                    args.io_sequence[i].slba = long(line[2])
                    args.io_sequence[i].timestamp = line[0]
                    args.io_sequence[i].op = line[1]
                    args.io_sequence[i].nlba = line[3]

            assert op_percentage is not None
            assert type(op_percentage) is dict
            args.op_list = <unsigned int*>PyMem_Malloc(sizeof(unsigned int)*len(op_percentage))
            args.op_counter = <unsigned long*>PyMem_Malloc(sizeof(unsigned long)*len(op_percentage))
            if not args.op_list or not args.op_counter:
                raise MemoryError()
            for i, k in enumerate(op_percentage):
                args.op_list[i] = k
                args.op_counter[i] = op_percentage[k]
            args.op_num = len(op_percentage)

            # create array for output data: io counter per second
            if output_io_per_second is not None:
                # need time duration to collect io counter per second data
                args.io_counter_per_second = <unsigned int*>PyMem_Malloc(seconds*sizeof(unsigned int))
                if not args.io_counter_per_second:
                    raise MemoryError()
                memset(args.io_counter_per_second, 0, seconds*sizeof(unsigned int))

            # create array for output data: io counter per latency
            if output_percentile_latency is not None:
                # 1-1000,000 us, all latency > 1s are counted as 1000,000us
                args.io_counter_per_latency = <unsigned long*>PyMem_Malloc(1000*1000*sizeof(unsigned long))
                if not args.io_counter_per_latency:
                    raise MemoryError()
                memset(args.io_counter_per_latency, 0, 1000*1000*sizeof(unsigned long))

            # create array for output data: io counter per second
            args.cmdlog_list_len = 0
            if output_cmdlog_list:
                # command dwords sorted by completion time
                args.cmdlog_list_len = len(output_cmdlog_list)
                args.cmdlog_list = <d.ioworker_cmdlog*>PyMem_Malloc(sizeof(d.ioworker_cmdlog)*len(output_cmdlog_list))
                if not args.cmdlog_list:
                    raise MemoryError()
                memset(args.cmdlog_list, 0, sizeof(d.ioworker_cmdlog)*len(output_cmdlog_list))

            # transfer agurments
            args.lba_start = lba_start
            args.lba_step = lba_step
            args.lba_random = lba_random
            args.region_start = region_start
            args.region_end = region_end
            args.iops = iops
            args.io_count = io_count
            args.seconds = seconds
            args.qdepth = qdepth
            args.pvalue = pvalue
            args.ptype = ptype

            # ready: create resources
            with locker:
                pcie = Pcie(pciaddr.decode('utf-8'))
                nvme0 = Controller(pcie, True)
                nvme0n1 = Namespace(nvme0, nsid, nlba_verify)
                qpair = Qpair(nvme0, max(2, qdepth), qprio)

            # set: all ioworkers created in recent seconds will start at the same time
            if time.time() > _IOWorker.target_start_time:
                _IOWorker.target_start_time = math.ceil(10*time.time())/10+0.1
            time.sleep(_IOWorker.target_start_time-time.time())

            # go: start at the same time
            error = d.ioworker_entry(nvme0n1._ns, qpair._qpair, &args, &rets)

            # transfer back iops counter per second: c => cython
            if output_io_per_second is not None:
                for i in range(seconds):
                    output_io_per_second.append(args.io_counter_per_second[i])

            # transfer back percentile latency: c => cython
            if output_percentile_latency is not None:
                output_io_per_latency = []
                for i in range(1000*1000):
                    output_io_per_latency.append(args.io_counter_per_latency[i])

            # transfer back: c => cython
            if output_cmdlog_list:
                assert type(output_cmdlog_list) is list, "must be a list for data output"
                for i in range(args.cmdlog_list_len):
                    cmd = args.cmdlog_list[i]
                    output_cmdlog_list[i] = cmd.lba, cmd.count, cmd.opcode

            # output all io counters
            for i in range(len(op_percentage)):
                op_percentage[args.op_list[i]] = args.op_counter[i]

        except Exception as e:
            logging.warning(e)
            warnings.warn(e)
            error = -1

        finally:
            # checkout timeout event
            if _timeout_happened:
                error = -3

            # feed return to main process
            rqueue.put((os.getpid(),
                        error,
                        rets,
                        output_io_per_second,
                        output_io_per_latency,
                        output_cmdlog_list,
                        op_percentage))

            with locker:
                # close resources in right order
                if 'qpair' in locals():
                    # fail fast to delete queue after power loss
                    orig = nvme0.timeout
                    if d.driver_config_read() & 0x10:
                        nvme0.timeout = 1000
                        # backup BAR and remap to another memory
                        d.nvme_bar_remap(nvme0.pcie._ctrlr)

                    try:
                        qpair.delete()
                    except:
                        pass

                    # use original timeout
                    if d.driver_config_read() & 0x10:
                        nvme0.timeout = orig
                        # use original BAR
                        d.nvme_bar_recover(nvme0.pcie._ctrlr)

                if 'nvme0n1' in locals():
                    nvme0n1.close()

                if 'pcie' in locals():
                    pcie.close()

            if args.io_sequence:
                PyMem_Free(args.io_sequence)

            if args.io_counter_per_second:
                PyMem_Free(args.io_counter_per_second)

            if args.io_counter_per_latency:
                PyMem_Free(args.io_counter_per_latency)

            if args.cmdlog_list_len:
                PyMem_Free(args.cmdlog_list)

            if args.distribution:
                PyMem_Free(args.distribution)

            if args.lba_size_list:
                PyMem_Free(args.lba_size_list)

            if args.lba_size_list_ratio:
                PyMem_Free(args.lba_size_list_ratio)

            if args.lba_size_list_align:
                PyMem_Free(args.lba_size_list_align)

            if args.op_list:
                PyMem_Free(args.op_list)

            if args.op_counter:
                PyMem_Free(args.op_counter)

            import gc; gc.collect()


def srand(seed):
    """manually setup random seed

    # Parameters
        seed (int): the seed to setup for both python and C library
    """

    logging.info("setup random seed: 0x%x" % seed)
    d.driver_srand(seed)
    random.seed(seed)


# module init, needs root privilege
if os.geteuid() == 0:
    # CTRL-c to exit
    signal.signal(signal.SIGINT, _interrupt_handler)
    # timeout
    signal.signal(signal.SIGALRM, _timeout_signal_handler)

    _reentry_flag_init()

    # config runtime: disable ASLR, 8T drive, S3
    subprocess.call('sudo ulimit -n 32000 2> /dev/null || true', shell=True)
    subprocess.call('sudo sh -c "echo deep > /sys/power/mem_sleep" 2> /dev/null || true', shell=True)
    subprocess.call('sudo sh -c "echo 0 > /proc/sys/kernel/randomize_va_space" 2> /dev/null || true', shell=True)

    # spawn only limited data from parent process
    _mp = multiprocessing.get_context("spawn")

    # init driver
    if d.driver_init() != 0:
        logging.error("driver initialization fail")
        raise SystemExit("driver initialization fail")

    # module fini
    atexit.register(d.driver_fini)
