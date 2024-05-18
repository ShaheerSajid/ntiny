# Importing Libraries
import serial
import time
import sys
import glob
import os

x = ""
def serial_ports():
    """ Lists serial port names
        :raises EnvironmentError:
            On unsupported or unknown platforms
        :returns:
            A list of the serial ports available on the system
    """
    if sys.platform.startswith('win'):
        ports = ['COM%s' % (i + 1) for i in range(256)]
    elif sys.platform.startswith('linux') or sys.platform.startswith('cygwin'):
        # this excludes your current terminal "/dev/tty"
        ports = glob.glob('/dev/tty[A-Za-z]*')
    elif sys.platform.startswith('darwin'):
        ports = glob.glob('/dev/tty.*')
    else:
        raise EnvironmentError('Unsupported platform')

    result = ""
    for port in ports:
        try:
            s = serial.Serial(port, baudrate=115200, timeout=1)
            time.sleep(2)
            s.write(bytes('I', 'utf-8'))
            data = s.readline()
            s.close()
            if(data == b'10E31913'):
                print("Device ID: ", end = "")
                print(data, end = "")
                print("\tNtiny Found!")
                result = port
        except (OSError, serial.SerialException):
            pass
    return result

if __name__ == '__main__':

    # total arguments
    n = len(sys.argv)
    if(n != 2):
        print("No BIN file specified.")
        exit()
    print("#############################################################################")   
    print(" _   _ _______ _____ _   ___     __     ______ _                _____ _    _ ") 
    print("| \ | |__   __|_   _| \ | \ \   / /    |  ____| |        /\    / ____| |  | |") 
    print("|  \| |  | |    | | |  \| |\ \_/ /     | |__  | |       /  \  | (___ | |__| |") 
    print("| . ` |  | |    | | | . ` | \   /      |  __| | |      / /\ \  \___ \|  __  |") 
    print("| |\  |  | |   _| |_| |\  |  | |       | |    | |____ / ____ \ ____) | |  | |") 
    print("|_| \_|  |_|  |_____|_| \_|  |_|       |_|    |______/_/    \_\_____/|_|  |_|") 
    print("#############################################################################")
    print("\n\nScanning...",)
    port = serial_ports()
    if(port != ''):
        s = serial.Serial(port, baudrate=115200, timeout=1)
        time.sleep(2)
    else:  
        print("No Device Found")
        exit()
    #erase
    print("Erasing... ") 
    s.write(bytes('E', 'utf-8'))
    data = ""
    while data != b'Erased\r\n':
        data = s.readline()
    print("Done")
    s.write(bytes('X', 'utf-8'))
    s.flush()
    #program
    bin = sys.argv[1]
    print("Programming... ")
    with open(bin, mode='rb') as file: # b is important -> binary
        file_size = os.path.getsize(bin)
        print("Size: ", end="")
        print(file_size)
        cnt = 0
        while 1:
            b0 = file.read(1)
            if not b0:
                break
            s.write(bytes('P', 'utf-8'))
            s.write(b0)
            data = ""
            while data != b'OK\r\n':
                data = s.readline()
            s.write(bytes('X', 'utf-8'))
            s.flush()
            print("Uploaded : %3.2f%%" % (cnt*100.0/file_size), end="\r")
            cnt = cnt+1
    print("\nDone")
    
    #clear address
    s.write(bytes('C', 'utf-8'))
    data = ""
    while data != b'Cleared\r\n':
        data = s.readline()
    s.write(bytes('X', 'utf-8'))
    s.flush()
    s.close()
    exit()
                                                                            
