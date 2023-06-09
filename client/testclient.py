import socket
import numpy as np
import sigdatafmt

# サーバーIPとポート番号
IPADDR = "127.0.0.1";
PORT = 8888;

nTXUSRP = 2
nRXUSPR = 2


with socket.socket(socket.AF_INET,socket.SOCK_STREAM) as sock:
    sock.connect((IPADDR, PORT));
    while True:
        cmd = input("Transmit, Receive, or Quit (t/r/q): ");

        if cmd.startswith("t"):
            size = int(input("signal size: "));

            print("\tGenerating {} complex random samples...".format(size));

            # [I+jQ, I+jQ, I+jQ, ...]
            data = np.random.uniform(-1, 1, size=size) + np.random.uniform(-1, 1, size=size) * 1j;

            print("\tFirst 10 elements: {}".format(data[:10]));
            print("\tLast 10 elements: {}".format(data[-10:]));

            # 送信リクエストのヘッダー（0x53）
            sock.sendall(b'T');

            # サーバー側に信号データ長とデータ本体を送る
            for i in range(nTXUSRP):
                if i == 0:
                    sigdatafmt.writeSignalToSock(sock, data, withHeader=True)
                else:
                    sigdatafmt.writeSignalToSock(sock, data, withHeader=False)

            # # サーバー側から受信データを取得
            # recvdata = sigdatafmt.readSignalFromSock(sock)
            # print("[Response]");
            # print("\tFirst 10 elements: {}".format(recvdata[:10]));
            # print("\tLast 10 elements: {}".format(recvdata[-10:]));

        elif cmd.startswith("r"):

            # サーバー側に受信データのリクエストを送る
            sock.sendall(b'R');

            size = int(input("signal size: "))
            # 要求するサンプル数を送る
            sigdatafmt.writeInt32ToSock(sock, size)

            # サーバー側からの応答を読む
            for i in range(nRXUSPR):
                data = sigdatafmt.readSignalFromSock(sock, size)
                print("[Response {}]".format(i));
                print("\tFirst 10 elements: {}".format(data[:10]));
                print("\tLast 10 elements: {}".format(data[-10:]));

        elif cmd.startswith("q"):
            sock.sendall(b'Q');
            break;

        else:
            print("Undefined command");
