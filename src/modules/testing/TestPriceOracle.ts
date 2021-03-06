import BigNumber from 'bignumber.js';
import { Contracts } from '../../lib/Contracts';
import { ContractCallOptions, TxResult, address, Integer } from '../../types';

export class TestPriceOracle {
  private contracts: Contracts;

  constructor(
    contracts: Contracts,
  ) {
    this.contracts = contracts;
  }

  public getAddress(): string {
    return this.contracts.testPriceOracle.options.address;
  }

  public async setPrice(
    token: address,
    price: Integer,
    options?: ContractCallOptions,
  ): Promise<TxResult> {
    return this.contracts.callContractFunction(
      this.contracts.testPriceOracle.methods.setPrice(
        token,
        price.toFixed(0),
      ),
      options,
    );
  }

  public async getPrice(
    token: address,
  ): Promise<Integer> {
    const price = await this.contracts.testPriceOracle.methods.getPrice(token).call();
    return new BigNumber(price.value);
  }
}
